import Foundation

public enum SensorGroup: String, Sendable {
    case cpu, gpu, other
}

public enum MonitorScope: String, CaseIterable, Sendable {
    case cpuMaximum = "cpu-max"
    case cpuAverage = "cpu-average"
    case gpuMaximum = "gpu-max"

    public var label: String {
        switch self {
        case .cpuMaximum: return "CPU 最高温度"
        case .cpuAverage: return "CPU 平均温度"
        case .gpuMaximum: return "GPU 最高温度"
        }
    }
}

public struct TemperatureSensor: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let group: SensorGroup
    public init(id: String, name: String, group: SensorGroup) {
        self.id = id
        self.name = name
        self.group = group
    }

    /// Exclude proximity, heatsink and package readings from the core average.
    public var isCPUCore: Bool {
        guard group == .cpu else { return false }
        if id.hasPrefix("Tp") || id.hasPrefix("Te") { return true }
        let key = Array(id.utf8)
        return key.count == 4 && key[0] == 84 && key[1] == 67 &&
            ((48...57).contains(key[2]) || key[2] == 65 || key[2] == 66) &&
            (key[3] == 67 || key[3] == 99)
    }
}

public enum SensorSelection {
    public static func sensors(for id: String, in sensors: [TemperatureSensor]) -> [TemperatureSensor] {
        switch id {
        case "cpu-max": return sensors.filter { $0.group == .cpu }
        case "cpu-average": return sensors.filter(\.isCPUCore)
        case "gpu-max": return sensors.filter { $0.group == .gpu }
        case "all-max": return sensors
        default: return sensors.filter { $0.id == id }
        }
    }

    public static func label(for id: String, in sensors: [TemperatureSensor]) -> String {
        if let scope = MonitorScope(rawValue: id) { return scope.label }
        switch id {
        case "all-max": return "所有传感器最高温度"
        default: return sensors.first { $0.id == id }?.name ?? "传感器 \(id)（不可用）"
        }
    }

    /// Require every selected sensor to be present: partial readings must not establish
    /// continuity or rearm an episode by accidentally omitting the hottest sensor.
    public static func temperature(for id: String, sensors: [TemperatureSensor], readings: [String: Double]) -> Double? {
        let selected = self.sensors(for: id, in: sensors)
        guard !selected.isEmpty else { return nil }
        let values = selected.compactMap { readings[$0.id] }
        guard values.count == selected.count, values.allSatisfy({ $0.isFinite && (0...150).contains($0) }) else { return nil }
        if id == MonitorScope.cpuAverage.rawValue { return values.reduce(0, +) / Double(values.count) }
        return values.max()
    }
}
