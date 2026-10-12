import Foundation
import Testing
@testable import TemperatureCore
import TemperatureIPC

struct IPCStateTests {
    @Test func initialSnapshotAndDeltaPreserveGapsWithoutDuplicateSamples() throws {
        var source = TemperatureHistory()
        source.append(temperature: 40, at: 0, sampleInterval: 1)
        source.append(temperature: nil, at: 1, sampleInterval: 1)
        source.append(temperature: 42, at: 2, sampleInterval: 1)
        var state = MonitorState()
        state.sampleTime = 2
        state.history = source.points(in: 60, endingAt: 2)
        state.latestPoint = source.latestPoint
        state.notificationAuthorization = 2
        state.lastAlert = Date(timeIntervalSince1970: 100)
        var mirror = HistoryMirror()
        let decoded = try JSONDecoder().decode(MonitorState.self, from: JSONEncoder().encode(state))
        mirror.receive(decoded)
        #expect(decoded.lastAlert == state.lastAlert)
        #expect(decoded.notificationAuthorization == 2)
        #expect(mirror.count == 3)
        state.history = nil
        mirror.receive(state)
        mirror.receive(state)
        #expect(mirror.count == 3)
        source.append(temperature: 43, at: 3, sampleInterval: 1)
        state.latestPoint = source.latestPoint
        state.sampleTime = 3
        mirror.receive(state)
        #expect(mirror.points(in: 60, endingAt: 3) == source.points(in: 60, endingAt: 3))
    }

    @Test func historyClearAndScopeChangesDiscardOldPoints() {
        var source = TemperatureHistory()
        source.append(temperature: 60, at: 1, sampleInterval: 1)
        var state = MonitorState()
        state.latestPoint = source.latestPoint
        var mirror = HistoryMirror()
        mirror.receive(state)
        #expect(mirror.count == 1)
        state.historyEpoch = UUID()
        state.latestPoint = nil
        mirror.receive(state)
        #expect(mirror.count == 0)
        source.clear()
        source.append(temperature: 45, at: 2, sampleInterval: 1)
        state.settings.sensorID = "gpu-max"
        state.latestPoint = source.latestPoint
        mirror.receive(state)
        #expect(mirror.points(in: 60, endingAt: 2).map(\.temperature) == [45])
    }

    @Test func longRunningStreamRemainsBoundedAndCanRecoverAfterClockRollback() {
        var source = TemperatureHistory()
        var state = MonitorState()
        state.settings.sampleInterval = 0.5
        var mirror = HistoryMirror()
        for index in 0...2400 {
            let time = Double(index) * 0.5
            source.append(temperature: 50, at: time, sampleInterval: 0.5)
            state.latestPoint = source.latestPoint
            state.sampleTime = time
            mirror.receive(state)
        }
        #expect(mirror.count == TemperatureHistory.capacity)
        #expect(mirror.points(in: 600, endingAt: 1200) == source.points(in: 600, endingAt: 1200))
        source.append(temperature: 40, at: 0, sampleInterval: 0.5)
        state.latestPoint = source.latestPoint
        state.sampleTime = 0
        mirror.receive(state)
        #expect(mirror.count == 1)
        #expect(mirror.points(in: 60, endingAt: 0).first?.startsNewSegment == true)
    }
}
