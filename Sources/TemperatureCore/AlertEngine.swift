import Foundation

public struct TemperatureAlert: Equatable, Sendable {
    public let temperature: Double
    public let elapsed: TimeInterval
}

/// Evaluates sampled temperatures against elapsed monotonic time, never sample counts.
public struct AlertEngine: Sendable {
    public private(set) var aboveSince: TimeInterval?
    public private(set) var isLatched = false
    public private(set) var lastAlertAt: TimeInterval?
    private var previousSampleAt: TimeInterval?

    public init() {}

    public mutating func reset(preservingCooldown: Bool = true) {
        aboveSince = nil
        previousSampleAt = nil
        isLatched = false
        if !preservingCooldown { lastAlertAt = nil }
    }

    public mutating func evaluate(
        temperature: Double?, at time: TimeInterval, settings: MonitorSettings
    ) -> TemperatureAlert? {
        let rule = settings.validated()
        guard rule.isEnabled else {
            reset()
            return nil
        }
        // Missing/delayed samples break the evidence of continuity. A latched episode
        // stays latched until an actual cool reading arrives, avoiding repeat alerts.
        if let previous = previousSampleAt,
           time < previous || time - previous > rule.sampleInterval * 1.6 + 0.2 {
            aboveSince = nil
        }
        previousSampleAt = time
        guard let temperature, temperature.isFinite, (0...150).contains(temperature) else {
            aboveSince = nil
            return nil
        }
        if isLatched {
            if temperature < rule.threshold,
               temperature <= rule.threshold - rule.hysteresis {
                isLatched = false
                aboveSince = nil
            }
            return nil
        }
        guard temperature >= rule.threshold else {
            aboveSince = nil
            return nil
        }
        if aboveSince == nil { aboveSince = time }
        let elapsed = max(0, time - (aboveSince ?? time))
        guard elapsed >= rule.duration else { return nil }
        if let lastAlertAt, time - lastAlertAt < rule.cooldown { return nil }
        isLatched = true
        lastAlertAt = time
        return TemperatureAlert(temperature: temperature, elapsed: elapsed)
    }

    public func elapsed(at time: TimeInterval) -> TimeInterval {
        guard let aboveSince, !isLatched else { return 0 }
        return max(0, time - aboveSince)
    }
}
