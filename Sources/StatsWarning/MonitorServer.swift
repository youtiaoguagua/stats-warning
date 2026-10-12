import AppKit
import Darwin
import Foundation
import TemperatureCore
import TemperatureIPC

@MainActor
final class MonitorServer {
    private struct Client {
        let channel: IPCChannel
        var subscribed = false
    }
    private var listener: IPCListener?
    private let model: MonitorModel
    let endpointURL: URL
    private var clients: [UUID: Client] = [:]
    private var stopped = false

    init(model: MonitorModel) throws {
        self.model = model
        endpointURL = try IPCPaths.endpoint(for: getpid())
        listener = try IPCListener(url: endpointURL) { [weak self] descriptor in
            Task { @MainActor in
                guard let self, !self.stopped else { Darwin.close(descriptor); return }
                let identity = UUID()
                do {
                    let channel = try IPCChannel(descriptor: descriptor, onData: { [weak self] data in
                        Task { @MainActor in await self?.receive(data, from: identity) }
                    }, onClose: { [weak self] in
                        Task { @MainActor in _ = self?.clients.removeValue(forKey: identity) }
                    })
                    self.clients[identity] = Client(channel: channel)
                } catch { Darwin.close(descriptor) }
            }
        }
    }

    func stop() {
        stopped = true
        for client in clients.values { client.channel.close() }
        clients.removeAll()
        listener?.close()
        listener = nil
    }

    func broadcast() {
        let subscribers = clients.values.filter(\.subscribed)
        guard !subscribers.isEmpty, let data = try? JSONEncoder().encode(IPCPacket.state(model.makeState())) else { return }
        for client in subscribers { try? client.channel.send(data) }
    }

    private func receive(_ data: Data, from identity: UUID) async {
        guard !stopped, clients[identity] != nil else { return }
        guard let packet = try? JSONDecoder().decode(IPCPacket.self, from: data),
              case .request(let request) = packet else { clients[identity]?.channel.close(); return }
        if request.operation == "subscribe" {
            clients[identity]?.subscribed = true
            reply(request, to: identity, includeHistory: true)
            return
        }
        guard clients[identity]?.subscribed == true else { return }
        if request.operation == "updateSettings" {
            guard let settings = request.settings else { reply(request, to: identity, error: "设置为空。"); return }
            model.update { $0 = settings.validated() }
            reply(request, to: identity)
            return
        }
        guard let command = MonitorCommand(rawValue: request.operation) else {
            reply(request, to: identity, error: "未知操作。"); return
        }
        switch command {
        case .refreshAuthorization: await model.refreshAuthorization()
        case .allowNotifications: model.allowNotifications()
        case .testNotification: model.testNotification()
        case .rescan: model.rescan()
        case .clearHistory: model.clearHistory()
        case .enableLogin: model.setLaunchAtLogin(true)
        case .disableLogin: model.setLaunchAtLogin(false)
        case .quit:
            reply(request, to: identity)
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        reply(request, to: identity)
    }

    private func reply(_ request: IPCRequest, to identity: UUID, includeHistory: Bool = false, error: String? = nil) {
        guard let client = clients[identity] else { return }
        do {
            let reply = IPCReply(id: request.id, state: model.makeState(includeHistory: includeHistory), error: error)
            try client.channel.send(JSONEncoder().encode(IPCPacket.reply(reply)))
        } catch { client.channel.close() }
    }
}
