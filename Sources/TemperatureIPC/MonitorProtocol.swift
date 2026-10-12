import Foundation
import TemperatureCore

public enum MonitorCommand: String {
    case refreshAuthorization, allowNotifications, testNotification, rescan, clearHistory
    case enableLogin, disableLogin, quit
}

public struct IPCRequest: Codable, Sendable {
    public let id: UUID
    public let operation: String
    public let settings: MonitorSettings?
    public init(operation: String, settings: MonitorSettings? = nil) {
        id = UUID()
        self.operation = operation
        self.settings = settings
    }
}

public struct IPCReply: Codable, Sendable {
    public let id: UUID
    public let state: MonitorState?
    public let error: String?
    public init(id: UUID, state: MonitorState? = nil, error: String? = nil) {
        self.id = id; self.state = state; self.error = error
    }
}

public enum IPCPacket: Codable, Sendable {
    case request(IPCRequest), reply(IPCReply), state(MonitorState)
}

public enum IPCPaths {
    public static func endpoint(for pid: Int32) throws -> URL {
        let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
            .appendingPathComponent("io.local.stats-warning", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let token = UUID().uuidString.prefix(8).lowercased()
        return directory.appendingPathComponent("monitor-\(pid)-\(token).sock")
    }
}
