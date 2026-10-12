import Foundation
import TemperatureCore

/// Full history is sent on connection only; subsequent updates carry one sample.
public struct MonitorState: Codable, Sendable {
    public var revision: UInt64 = 0
    public var settings: MonitorSettings
    public var temperature: Double?
    public var sensorError: String?
    public var sensorCount = 0
    public var selectionLabel = "CPU 最高温度"
    public var stateLabel = "正在连接监控"
    public var elapsed: TimeInterval = 0
    public var isLatched = false
    public var lastAlert: Date?
    public var notificationAuthorization = 0
    public var launchAtLogin = false
    public var loginRequiresApproval: Bool?
    public var message: String?
    public var isTestingNotification = false
    public var sampleTime: TimeInterval = 0
    public var historyEpoch = UUID()
    public var history: [TemperaturePoint]?
    public var latestPoint: TemperaturePoint?

    public init(settings: MonitorSettings = MonitorSettings()) { self.settings = settings }
}

/// Mirror the monitor's bounded history without polling or duplicating samples
/// when the same state arrives through both an RPC reply and a pushed update.
public struct HistoryMirror: Sendable {
    private var history = TemperatureHistory()
    private var epoch: UUID?
    private var latestTime: TimeInterval?

    public init() {}
    public var count: Int { history.count }

    public mutating func receive(_ state: MonitorState) {
        if epoch != state.historyEpoch {
            history.clear()
            latestTime = nil
            epoch = state.historyEpoch
        }
        if let initial = state.history {
            history.clear()
            latestTime = nil
            for point in initial { append(point, interval: state.settings.sampleInterval) }
        }
        if let point = state.latestPoint, point.time != latestTime {
            append(point, interval: state.settings.sampleInterval)
        }
    }

    private mutating func append(_ point: TemperaturePoint, interval: TimeInterval) {
        if point.startsNewSegment { history.breakContinuity() }
        history.append(temperature: point.temperature, at: point.time, sampleInterval: interval)
        latestTime = point.time
    }

    public func points(in window: TimeInterval, endingAt time: TimeInterval) -> [TemperaturePoint] {
        history.points(in: window, endingAt: time)
    }
}
