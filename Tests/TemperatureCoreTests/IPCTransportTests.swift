import Darwin
import Foundation
import Testing
import TemperatureIPC

struct IPCTransportTests {
    @Test func splitHeadersBodiesAndCoalescedMessagesRoundTrip() throws {
        let first = Data("温度 70°C".utf8)
        let second = Data("second".utf8)
        let framed = try IPCFrameDecoder.frame(first) + IPCFrameDecoder.frame(second)
        var decoder = IPCFrameDecoder()
        var received: [Data] = []
        for byte in framed { received.append(contentsOf: try decoder.append(Data([byte]))) }
        #expect(received == [first, second])
        var coalesced = IPCFrameDecoder()
        #expect(try coalesced.append(framed) == [first, second])
    }

    @Test func rejectsEmptyAndOversizedFramesBeforeWaitingForBody() {
        var decoder = IPCFrameDecoder()
        #expect(throws: IPCError.self) { try decoder.append(Data([0, 0, 0, 0])) }
        var tooLarge = UInt32(IPCFrameDecoder.maximumSize + 1).bigEndian
        let header = withUnsafeBytes(of: &tooLarge) { Data($0) }
        var second = IPCFrameDecoder()
        #expect(throws: IPCError.self) { try second.append(header) }
        #expect(throws: IPCError.self) { try IPCFrameDecoder.frame(Data()) }
    }

    @Test func localStreamHandlesPayloadLargerThanReadBuffer() async throws {
        let url = URL(fileURLWithPath: "/tmp/stats-warning-test-\(UUID().uuidString).sock")
        let echo = EchoPeer()
        let listener = try IPCListener(url: url) { [echo] descriptor in
            do {
                let channel = try IPCChannel(descriptor: descriptor, onData: { [weak echo] data in echo?.send(data) }, onClose: {})
                echo.attach(channel)
            } catch { Darwin.close(descriptor) }
        }
        defer { echo.close(); listener.close() }
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let client = try IPCChannel.connect(to: url, onData: { continuation.yield($0) }, onClose: { continuation.finish() })
        defer { client.close() }
        let payload = Data(repeating: 0xA5, count: 150_000)
        try client.send(payload)
        let received = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let message = await iterator.next() else { throw IPCError.invalidFrame }
                return message
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                throw IPCError.invalidFrame
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        #expect(received == payload)
    }

    @Test func failedBindDoesNotRemoveAnExistingListenersEndpoint() throws {
        let url = URL(fileURLWithPath: "/tmp/stats-warning-test-\(UUID().uuidString).sock")
        let listener = try IPCListener(url: url) { descriptor in _ = Darwin.close(descriptor) }
        defer { listener.close() }
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(throws: IPCError.self) {
            try IPCListener(url: url) { descriptor in _ = Darwin.close(descriptor) }
        }
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

private final class EchoPeer: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: IPCChannel?
    private var pending: [Data] = []
    func attach(_ channel: IPCChannel) {
        lock.lock(); defer { lock.unlock() }
        self.channel = channel
        for data in pending { try? channel.send(data) }
        pending.removeAll()
    }
    func send(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        if let channel { try? channel.send(data) }
        else { pending.append(data) }
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        channel?.close()
        channel = nil
        pending.removeAll()
    }
}
