import AppKit
import Foundation
import ServiceManagement
import TemperatureCore
import TemperatureIPC
import UserNotifications

@MainActor
final class SettingsModel {
    private var state = MonitorState()
    private(set) var isConnected = false
    private(set) var connectionError: String?
    private(set) var isUpdatingLogin = false
    var onChange: (() -> Void)?
    private var connection: IPCChannel?
    private var session = UUID()
    private var requests: [UUID: (MonitorState?, String?) -> Void] = [:]
    private var history = HistoryMirror()
    private var receivedRevision: UInt64?
    private var initialUpdates: [MonitorState] = []
    private var pendingSettings: MonitorSettings?
    private var settingsRequest: UInt64 = 0
    private let endpointURL: URL

    init(endpointURL: URL) { self.endpointURL = endpointURL }

    var settings: MonitorSettings { state.settings }
    var temperature: Double? { state.temperature }
    var sensorError: String? { state.sensorError }
    var sensorCount: Int { state.sensorCount }
    var stateLabel: String { state.stateLabel }
    var elapsed: TimeInterval { state.elapsed }
    var isLatched: Bool { state.isLatched }
    var lastAlert: Date? { state.lastAlert }
    var launchAtLogin: Bool { state.launchAtLogin }
    var loginRequiresApproval: Bool { state.loginRequiresApproval == true }
    var message: String? { connectionError ?? state.message }
    var isTestingNotification: Bool { state.isTestingNotification }
    var sampleTime: TimeInterval { state.sampleTime }
    var notificationStatus: UNAuthorizationStatus {
        UNAuthorizationStatus(rawValue: state.notificationAuthorization) ?? .notDetermined
    }
    var notificationAllowed: Bool { notificationStatus == .authorized || notificationStatus == .provisional }

    func connect() {
        disconnect()
        connectionError = nil
        receivedRevision = nil
        initialUpdates.removeAll()
        pendingSettings = nil
        isUpdatingLogin = false
        let session = UUID()
        self.session = session
        do {
            connection = try IPCChannel.connect(to: endpointURL, onData: { [weak self] data in
                Task { @MainActor in
                    guard let self, self.session == session else { return }
                    self.receive(data)
                }
            }, onClose: { [weak self] in
                Task { @MainActor in
                    guard let self, self.session == session else { return }
                    self.connection = nil
                    self.isConnected = false
                    // No idle UI process survives a stopped or crashed monitor.
                    NSApp.terminate(nil)
                }
            })
            request("subscribe") { [weak self] snapshot, error in
                guard let self else { return }
                if let error { self.connectionError = error; return }
                guard let snapshot else { self.connectionError = "监控返回了空状态。"; return }
                self.apply(snapshot)
                self.isConnected = true
                for update in self.initialUpdates.sorted(by: { $0.revision < $1.revision }) { self.apply(update) }
                self.initialUpdates.removeAll()
                self.onChange?()
            }
        } catch { connectionError = "无法连接监控，请重新打开温度提醒应用。\(error.localizedDescription)" }
        onChange?()
    }

    func disconnect() {
        session = UUID()
        connection?.close()
        connection = nil
        requests.removeAll()
        isConnected = false
        onChange?()
    }

    private func receive(_ data: Data) {
        do {
            switch try JSONDecoder().decode(IPCPacket.self, from: data) {
            case .state(let snapshot):
                if isConnected { apply(snapshot) }
                else if initialUpdates.count < 8 { initialUpdates.append(snapshot) }
            case .reply(let reply): requests.removeValue(forKey: reply.id)?(reply.state, reply.error)
            case .request: connectionError = "监控返回了无效消息。"
            }
        } catch { connectionError = "无法读取监控状态：\(error.localizedDescription)" }
        if connectionError != nil { onChange?() }
    }

    private func request(_ operation: String, settings: MonitorSettings? = nil,
                         completion: @escaping (MonitorState?, String?) -> Void) {
        guard let connection else { completion(nil, "监控连接已关闭。"); return }
        let request = IPCRequest(operation: operation, settings: settings)
        requests[request.id] = completion
        do { try connection.send(JSONEncoder().encode(IPCPacket.request(request))) }
        catch {
            requests.removeValue(forKey: request.id)
            completion(nil, "无法同步设置：\(error.localizedDescription)")
        }
    }

    private func apply(_ snapshot: MonitorState) {
        guard receivedRevision == nil || snapshot.revision >= receivedRevision! else { return }
        receivedRevision = snapshot.revision
        history.receive(snapshot)
        var displayed = snapshot
        if let pendingSettings { displayed.settings = pendingSettings }
        state = displayed
        onChange?()
    }

    func historyPoints(in window: TimeInterval) -> [TemperaturePoint] {
        history.points(in: window, endingAt: sampleTime)
    }

    func update(_ mutation: (inout MonitorSettings) -> Void) {
        commit(mutation, completion: nil)
    }

    func updateRules(_ mutation: (inout MonitorSettings) -> Void, completion: @escaping (Bool) -> Void) {
        commit(mutation, completion: completion)
    }

    private func commit(_ mutation: (inout MonitorSettings) -> Void, completion: ((Bool) -> Void)?) {
        guard isConnected else { completion?(false); return }
        var changed = settings
        mutation(&changed)
        changed = changed.validated()
        guard changed != settings else { completion?(true); return }
        settingsRequest &+= 1
        let identifier = settingsRequest
        pendingSettings = changed
        state.settings = changed
        onChange?()
        request("updateSettings", settings: changed) { [weak self] snapshot, error in
            guard let self else { return }
            if identifier == self.settingsRequest { self.pendingSettings = nil }
            if let error { self.connectionError = error; self.onChange?() }
            if let snapshot { self.apply(snapshot) }
            completion?(error == nil && snapshot != nil)
        }
    }

    private func send(_ command: MonitorCommand) {
        guard isConnected else { return }
        request(command.rawValue) { [weak self] snapshot, error in
            guard let self else { return }
            if let error { self.connectionError = error; self.onChange?() }
            if let snapshot { self.apply(snapshot) }
        }
    }

    func refreshAuthorization() { send(.refreshAuthorization) }
    func allowNotifications() { send(.allowNotifications) }
    func testNotification() { send(.testNotification) }
    func rescan() { send(.rescan) }
    func clearHistory() { send(.clearHistory) }
    func quitMonitoring() { send(.quit) }
    func setLaunchAtLogin(_ enabled: Bool) {
        guard isConnected, !isUpdatingLogin else { return }
        isUpdatingLogin = true
        onChange?()
        request((enabled ? MonitorCommand.enableLogin : .disableLogin).rawValue) { [weak self] snapshot, error in
            guard let self else { return }
            self.isUpdatingLogin = false
            if let error { self.connectionError = error }
            if let snapshot { self.apply(snapshot) }
            else { self.onChange?() }
        }
    }
    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

