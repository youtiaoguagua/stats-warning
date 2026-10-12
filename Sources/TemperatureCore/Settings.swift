import Foundation

public enum MenuBarIcon: String, Codable, CaseIterable, Sendable {
    case thermometer, flame, chip

    public var label: String {
        switch self {
        case .thermometer: return "温度计"
        case .flame: return "火焰"
        case .chip: return "芯片"
        }
    }

    public var symbolName: String {
        switch self {
        case .thermometer: return "thermometer.medium"
        case .flame: return "flame"
        case .chip: return "cpu"
        }
    }
}

public enum MenuBarDisplay: String, Codable, CaseIterable, Sendable {
    case iconAndTemperature, temperatureOnly, iconOnly

    public var label: String {
        switch self {
        case .iconAndTemperature: return "图标和温度"
        case .temperatureOnly: return "仅温度"
        case .iconOnly: return "仅图标"
        }
    }

    public var showsIcon: Bool { self != .temperatureOnly }
    public var showsTemperature: Bool { self != .iconOnly }
}

public struct MonitorSettings: Codable, Equatable, Sendable {
    public var threshold: Double = 70
    public var duration: TimeInterval = 2
    public var sampleInterval: TimeInterval = 1
    public var cooldown: TimeInterval = 60
    public var hysteresis: Double = 3
    public var sensorID: String = "cpu-max"
    public var isEnabled = true
    public var playsSound = true

    public var showsMenuBarItem = true
    public var menuBarIcon: MenuBarIcon = .thermometer
    public var menuBarDisplay: MenuBarDisplay = .iconAndTemperature

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case threshold, duration, sampleInterval, cooldown, hysteresis, sensorID, isEnabled, playsSound
        case showsMenuBarItem, menuBarIcon, menuBarDisplay
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Keep existing rules when upgrading preferences saved before appearance settings existed.
        threshold = try values.decodeIfPresent(Double.self, forKey: .threshold) ?? 70
        duration = try values.decodeIfPresent(Double.self, forKey: .duration) ?? 2
        sampleInterval = try values.decodeIfPresent(Double.self, forKey: .sampleInterval) ?? 1
        cooldown = try values.decodeIfPresent(Double.self, forKey: .cooldown) ?? 60
        hysteresis = try values.decodeIfPresent(Double.self, forKey: .hysteresis) ?? 3
        sensorID = try values.decodeIfPresent(String.self, forKey: .sensorID) ?? "cpu-max"
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        playsSound = try values.decodeIfPresent(Bool.self, forKey: .playsSound) ?? true
        showsMenuBarItem = try values.decodeIfPresent(Bool.self, forKey: .showsMenuBarItem) ?? true
        menuBarIcon = MenuBarIcon(rawValue: try values.decodeIfPresent(String.self, forKey: .menuBarIcon) ?? "") ?? .thermometer
        menuBarDisplay = MenuBarDisplay(rawValue: try values.decodeIfPresent(String.self, forKey: .menuBarDisplay) ?? "") ?? .iconAndTemperature
    }

    public func validated() -> Self {
        var value = self
        value.threshold = threshold.isFinite ? min(120, max(30, threshold)) : 70
        value.duration = duration.isFinite ? min(600, max(0.5, duration)) : 2
        value.sampleInterval = sampleInterval.isFinite ? min(60, max(0.5, sampleInterval)) : 1
        value.cooldown = cooldown.isFinite ? min(3600, max(0, cooldown)) : 60
        value.hysteresis = hysteresis.isFinite ? min(10, max(0, hysteresis)) : 3
        // Migrate retired aggregate / individual selections to the primary CPU scope.
        if MonitorScope(rawValue: sensorID) == nil { value.sensorID = MonitorScope.cpuMaximum.rawValue }
        return value
    }
}
