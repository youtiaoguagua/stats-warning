import Darwin
import Dispatch
import Foundation

public enum IPCError: LocalizedError {
    case system(Int32), invalidFrame, pathTooLong
    public var errorDescription: String? {
        switch self {
        case .system(let code): return String(cString: strerror(code))
        case .invalidFrame: return "无效或过大的监控消息。"
        case .pathTooLong: return "监控连接路径过长。"
        }
    }
}

/// Length-prefix framing handles partial and coalesced reads, with bounded input.
public struct IPCFrameDecoder {
    public static let maximumSize = 512 * 1024
    private var buffer = Data()
    public init() {}

    public static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= maximumSize else { throw IPCError.invalidFrame }
        var length = UInt32(payload.count).bigEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }
        result.append(payload)
        return result
    }

    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let prefix = Array(buffer.prefix(4))
            let size = Int(UInt32(prefix[0]) << 24 | UInt32(prefix[1]) << 16 | UInt32(prefix[2]) << 8 | UInt32(prefix[3]))
            guard size > 0, size <= Self.maximumSize else { throw IPCError.invalidFrame }
            guard buffer.count >= size + 4 else { break }
            let start = buffer.startIndex + 4
            frames.append(buffer.subdata(in: start..<(start + size)))
            buffer.removeFirst(size + 4)
        }
        return frames
    }
}

private func withSocketAddress<T>(_ url: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
    var address = sockaddr_un()
    let bytes = Array(url.path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw IPCError.pathTooLong }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes) }
    return try withUnsafePointer(to: &address) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func configure(_ descriptor: Int32) throws {
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw IPCError.system(errno) }
    var enabled: Int32 = 1
    guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0 else {
        throw IPCError.system(errno)
    }
}

private final class DescriptorLifetime: @unchecked Sendable {
    let descriptor: Int32
    init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }
}

/// Mutable buffers and descriptor operations are confined to one utility queue.
/// Public calls only enqueue work; callbacks deliver immutable Data to the owner.
public final class IPCChannel: @unchecked Sendable {
    private let descriptor: Int32
    private let lifetime: DescriptorLifetime
    private let queue = DispatchQueue(label: "temperature.ipc.channel", qos: .utility)
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var decoder = IPCFrameDecoder()
    private var readBuffer = [UInt8](repeating: 0, count: 8192)
    private var outgoing: [Data] = []
    private var writeOffset = 0
    private var queuedBytes = 0
    private var closed = false
    private let onData: @Sendable (Data) -> Void
    private let onClose: @Sendable () -> Void

    public init(descriptor: Int32, onData: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) throws {
        try configure(descriptor)
        self.descriptor = descriptor
        lifetime = DescriptorLifetime(descriptor)
        self.onData = onData
        self.onClose = onClose
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        readSource = source
        source.setEventHandler { [weak self] in self?.readAvailable() }
        let lease = lifetime
        source.setCancelHandler { withExtendedLifetime(lease) {} }
        source.resume()
    }

    public static func connect(to url: URL, onData: @escaping @Sendable (Data) -> Void,
                               onClose: @escaping @Sendable () -> Void) throws -> IPCChannel {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw IPCError.system(errno) }
        do {
            try withSocketAddress(url) { address, length in
                guard Darwin.connect(descriptor, address, length) == 0 else { throw IPCError.system(errno) }
            }
            return try IPCChannel(descriptor: descriptor, onData: onData, onClose: onClose)
        } catch { Darwin.close(descriptor); throw error }
    }

    public func send(_ data: Data) throws {
        let frame = try IPCFrameDecoder.frame(data)
        queue.async { [self] in
            guard !closed else { return }
            // A stalled UI cannot accumulate unbounded temperature updates.
            guard queuedBytes + frame.count <= IPCFrameDecoder.maximumSize * 2 else { closeOnQueue(); return }
            outgoing.append(frame)
            queuedBytes += frame.count
            writeAvailable()
        }
    }

    public func close() { queue.async { [self] in closeOnQueue() } }
    deinit { readSource?.cancel(); writeSource?.cancel() }

    private func readAvailable() {
        guard !closed else { return }
        while true {
            let capacity = readBuffer.count
            let count = Darwin.recv(descriptor, &readBuffer, capacity, 0)
            if count > 0 {
                do {
                    for frame in try decoder.append(Data(readBuffer.prefix(count))) { onData(frame) }
                } catch { closeOnQueue(); return }
            } else if count == 0 { closeOnQueue(); return }
            else if errno == EINTR { continue }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else { closeOnQueue(); return }
        }
    }

    private func writeAvailable() {
        guard !closed else { return }
        while let frame = outgoing.first {
            let count = frame.withUnsafeBytes { raw in
                Darwin.send(descriptor, raw.baseAddress!.advanced(by: writeOffset), frame.count - writeOffset, 0)
            }
            if count > 0 {
                writeOffset += count
                queuedBytes -= count
                if writeOffset == frame.count { outgoing.removeFirst(); writeOffset = 0 }
            } else if count < 0 && errno == EINTR { continue }
            else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writeSource == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
                    writeSource = source
                    source.setEventHandler { [weak self] in self?.writeAvailable() }
                    // Both dispatch sources share the descriptor. Close it only
                    // after every cancellation completes, before it can be reused.
                    let lease = lifetime
                    source.setCancelHandler { withExtendedLifetime(lease) {} }
                    source.resume()
                }
                return
            } else { closeOnQueue(); return }
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func closeOnQueue() {
        guard !closed else { return }
        closed = true
        writeSource?.cancel()
        writeSource = nil
        readSource?.cancel()
        readSource = nil
        outgoing.removeAll()
        queuedBytes = 0
        onClose()
    }
}

public final class IPCListener: @unchecked Sendable {
    private let source: DispatchSourceRead
    private let url: URL

    public init(url: URL, onAccept: @escaping @Sendable (Int32) -> Void) throws {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw IPCError.system(errno) }
        var ownsPath = false
        do {
            try configure(descriptor)
            try withSocketAddress(url) { address, length in
                guard Darwin.bind(descriptor, address, length) == 0 else { throw IPCError.system(errno) }
            }
            ownsPath = true
            guard chmod(url.path, 0o600) == 0, Darwin.listen(descriptor, 4) == 0 else { throw IPCError.system(errno) }
        } catch {
            Darwin.close(descriptor)
            if ownsPath { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        self.url = url
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor,
                                               queue: DispatchQueue(label: "temperature.ipc.listener", qos: .utility))
        source.setEventHandler {
            while true {
                let peer = Darwin.accept(descriptor, nil, nil)
                if peer < 0 {
                    if errno == EINTR { continue }
                    return
                }
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(peer, &uid, &gid) == 0, uid == geteuid() else { Darwin.close(peer); continue }
                onAccept(peer)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    public func close() { source.cancel(); try? FileManager.default.removeItem(at: url) }
    deinit { source.cancel(); try? FileManager.default.removeItem(at: url) }
}
