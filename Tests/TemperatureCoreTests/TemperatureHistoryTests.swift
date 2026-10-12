import Testing
@testable import TemperatureCore

struct TemperatureHistoryTests {
    @Test func fastestSamplingRetainsOnlyTenMinutesAfterMultipleWraps() {
        var history = TemperatureHistory()
        for index in 0...5_000 {
            history.append(temperature: Double(index % 100), at: Double(index) * 0.5, sampleInterval: 0.5)
        }
        let points = history.points(in: 600, endingAt: 2_500)
        #expect(history.count == 1_201)
        #expect(points.count == 1_201)
        #expect(points.first?.time == 1_900)
        #expect(points.last?.time == 2_500)
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.time < $1.time })
    }

    @Test func slowerSamplingExpiresOldPointsBeforeCapacityIsReached() {
        var history = TemperatureHistory()
        for index in 0...200 {
            history.append(temperature: 50, at: Double(index) * 5, sampleInterval: 5)
        }
        let points = history.points(in: 600, endingAt: 1_000)
        #expect(history.count == 121)
        #expect(points.count == 121)
        #expect(points.first?.time == 400)
        #expect(points.last?.time == 1_000)
    }

    @Test func bufferRefillsCorrectlyAfterMostSamplesExpire() {
        var history = TemperatureHistory()
        for index in 0...50 {
            history.append(temperature: 40, at: Double(index), sampleInterval: 1)
        }
        history.append(temperature: 60, at: 1_000, sampleInterval: 1)
        #expect(history.count == 1)
        for index in 1...2_000 {
            history.append(temperature: 61, at: 1_000 + Double(index) * 0.5, sampleInterval: 0.5)
        }
        let points = history.points(in: 600, endingAt: 2_000)
        #expect(points.count == 1_201)
        #expect(points.first?.time == 1_400)
        #expect(points.last?.time == 2_000)
    }

    @Test func failuresSleepAndLongGapsBreakTheCurve() {
        var history = TemperatureHistory()
        history.append(temperature: 50, at: 0, sampleInterval: 1)
        history.append(temperature: 51, at: 1, sampleInterval: 1)
        history.append(temperature: nil, at: 2, sampleInterval: 1)
        history.append(temperature: 52, at: 3, sampleInterval: 1)
        history.breakContinuity()
        history.append(temperature: 53, at: 4, sampleInterval: 1)
        history.append(temperature: 54, at: 20, sampleInterval: 1)
        history.append(temperature: .nan, at: 21, sampleInterval: 1)
        let points = history.points(in: 60, endingAt: 21)
        #expect(points[0].startsNewSegment)
        #expect(!points[1].startsNewSegment)
        #expect(points[2].temperature == nil)
        #expect(points[3].startsNewSegment)
        #expect(points[4].startsNewSegment)
        #expect(points[5].startsNewSegment)
        #expect(points[6].temperature == nil)
    }

    @Test func timeWindowUsesActualTimestampsAtDifferentIntervals() {
        var history = TemperatureHistory()
        for time in [0.0, 15, 65, 74, 120, 131] {
            history.append(temperature: 50, at: time, sampleInterval: 60)
        }
        #expect(history.points(in: 60, endingAt: 130).map(\.time) == [74, 120])
        #expect(history.points(in: 300, endingAt: 131).count == 6)
    }

    @Test func clearAndClockRollbackStartFreshHistory() {
        var history = TemperatureHistory()
        history.append(temperature: 50, at: 100, sampleInterval: 1)
        history.append(temperature: 51, at: 90, sampleInterval: 1)
        let points = history.points(in: 600, endingAt: 90)
        #expect(points.count == 1)
        #expect(points.first?.time == 90)
        #expect(points.first?.startsNewSegment == true)
        history.clear()
        #expect(history.count == 0)
        #expect(history.points(in: 600, endingAt: 100).isEmpty)
    }
}
