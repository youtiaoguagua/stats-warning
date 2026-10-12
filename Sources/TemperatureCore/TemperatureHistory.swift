import Foundation

public struct TemperaturePoint: Codable, Equatable, Sendable {
    public let time: TimeInterval
    public let temperature: Double?
    public let startsNewSegment: Bool
}

/// A bounded ring buffer. Only live in-memory samples are retained, never logs.
public struct TemperatureHistory: Sendable {
    public static let retention: TimeInterval = 600
    public static let capacity = 1_201 // 10 minutes at the minimum 0.5 s interval.
    private var storage: [TemperaturePoint] = []
    private var head = 0
    public private(set) var count = 0
    private var breakBeforeNextSample = false

    public init() { storage.reserveCapacity(Self.capacity) }

    public var latestPoint: TemperaturePoint? {
        count > 0 ? storage[(head + count - 1) % Self.capacity] : nil
    }

    public mutating func clear() {
        storage.removeAll(keepingCapacity: true)
        head = 0
        count = 0
        breakBeforeNextSample = false
    }

    public mutating func breakContinuity() { breakBeforeNextSample = true }

    public mutating func append(temperature: Double?, at time: TimeInterval, sampleInterval: TimeInterval) {
        guard time.isFinite else { return }
        var last = count > 0 ? storage[(head + count - 1) % Self.capacity] : nil
        if let previous = last, time < previous.time { clear(); last = nil }
        let valid = temperature.flatMap { $0.isFinite && (0...150).contains($0) ? $0 : nil }
        let maximumGap = max(0.5, sampleInterval.isFinite ? sampleInterval : 1) * 1.6 + 0.2
        let point = TemperaturePoint(
            time: time, temperature: valid,
            startsNewSegment: breakBeforeNextSample || last == nil ||
                last?.temperature == nil || time - (last?.time ?? time) > maximumGap
        )
        breakBeforeNextSample = false
        if storage.count < Self.capacity {
            storage.append(point)
            count += 1
        } else {
            let index = (head + count) % Self.capacity
            storage[index] = point
            if count == Self.capacity { head = (head + 1) % Self.capacity }
            else { count += 1 }
        }
        while count > 0, storage[head].time < time - Self.retention {
            head = (head + 1) % Self.capacity
            count -= 1
        }
    }

    public func points(in window: TimeInterval, endingAt time: TimeInterval) -> [TemperaturePoint] {
        guard window.isFinite, time.isFinite, count > 0 else { return [] }
        let lower = time - min(Self.retention, max(0, window))
        var result: [TemperaturePoint] = []
        result.reserveCapacity(count)
        for offset in 0..<count {
            let point = storage[(head + offset) % Self.capacity]
            if point.time >= lower, point.time <= time { result.append(point) }
        }
        return result
    }
}
