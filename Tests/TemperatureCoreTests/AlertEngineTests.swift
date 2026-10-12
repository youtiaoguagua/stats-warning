import Testing
@testable import TemperatureCore

struct AlertEngineTests {
    @Test func testInclusiveThresholdUsesElapsedTime() {
        var engine = AlertEngine()
        let settings = MonitorSettings()
        #expect(engine.evaluate(temperature: 70, at: 0, settings: settings) == nil)
        #expect(engine.evaluate(temperature: 70, at: 1, settings: settings) == nil)
        #expect(engine.evaluate(temperature: 70, at: 2, settings: settings)?.elapsed == 2)
        #expect(engine.evaluate(temperature: 90, at: 3, settings: settings) == nil)
    }

    @Test func testBriefDipRestartsContinuousDuration() {
        var engine = AlertEngine()
        let settings = MonitorSettings()
        for (time, value) in [(0.0, 75.0), (1, 69), (2, 75), (3, 75)] {
            #expect(engine.evaluate(temperature: value, at: time, settings: settings) == nil)
        }
        #expect(engine.evaluate(temperature: 75, at: 4, settings: settings) != nil)
    }

    @Test func testMissingAndNonfiniteReadingsRestartDuration() {
        for missing in [nil, Double.nan, Double.infinity, -1, 151] as [Double?] {
            var engine = AlertEngine()
            let settings = MonitorSettings()
            #expect(engine.evaluate(temperature: 75, at: 0, settings: settings) == nil)
            #expect(engine.evaluate(temperature: missing, at: 1, settings: settings) == nil)
            #expect(engine.evaluate(temperature: 75, at: 2, settings: settings) == nil)
            #expect(engine.evaluate(temperature: 75, at: 3, settings: settings) == nil)
            #expect(engine.evaluate(temperature: 75, at: 4, settings: settings) != nil)
        }
    }

    @Test func testDelayedSampleDoesNotCountAsContinuousHeat() {
        var engine = AlertEngine()
        let settings = MonitorSettings()
        #expect(engine.evaluate(temperature: 75, at: 0, settings: settings) == nil)
        #expect(engine.evaluate(temperature: 75, at: 20, settings: settings) == nil)
        #expect(engine.evaluate(temperature: 75, at: 21, settings: settings) == nil)
        #expect(engine.evaluate(temperature: 75, at: 22, settings: settings) != nil)
    }

    @Test func testConfigurableSamplingIntervalDoesNotChangeDurationToSampleCount() {
        var engine = AlertEngine()
        var settings = MonitorSettings()
        settings.sampleInterval = 5
        #expect(engine.evaluate(temperature: 75, at: 0, settings: settings) == nil)
        #expect(engine.evaluate(temperature: 75, at: 5, settings: settings)?.elapsed == 5)
    }

    @Test func testHysteresisAndCooldownBothApplyToNewEpisode() {
        var engine = AlertEngine()
        var settings = MonitorSettings()
        settings.cooldown = 5
        for time in 0...2 { _ = engine.evaluate(temperature: 75, at: Double(time), settings: settings) }
        #expect(engine.isLatched)
        #expect(engine.evaluate(temperature: 69, at: 3, settings: settings) == nil)
        #expect(engine.isLatched)
        #expect(engine.evaluate(temperature: 67, at: 4, settings: settings) == nil)
        #expect(!engine.isLatched)
        #expect(engine.evaluate(temperature: 75, at: 5, settings: settings) == nil)
        #expect(engine.evaluate(temperature: 75, at: 6, settings: settings) == nil)
        #expect(engine.evaluate(temperature: 75, at: 7, settings: settings) != nil)
    }

    @Test func testInvalidSampleDoesNotRearmLatchedEpisode() {
        var engine = AlertEngine()
        var settings = MonitorSettings()
        settings.cooldown = 0
        for time in 0...2 { _ = engine.evaluate(temperature: 75, at: Double(time), settings: settings) }
        #expect(engine.evaluate(temperature: nil, at: 3, settings: settings) == nil)
        for time in 4...10 { #expect(engine.evaluate(temperature: 75, at: Double(time), settings: settings) == nil) }
        #expect(engine.isLatched)
    }

    @Test func testZeroHysteresisStillRequiresBelowThreshold() {
        var engine = AlertEngine()
        var settings = MonitorSettings()
        settings.hysteresis = 0
        for time in 0...2 { _ = engine.evaluate(temperature: 70, at: Double(time), settings: settings) }
        #expect(engine.evaluate(temperature: 70, at: 3, settings: settings) == nil)
        #expect(engine.isLatched)
        #expect(engine.evaluate(temperature: 69.9, at: 4, settings: settings) == nil)
        #expect(!engine.isLatched)
    }

    @Test func testDisableAndResetDiscardPartialDuration() {
        var engine = AlertEngine()
        var settings = MonitorSettings()
        _ = engine.evaluate(temperature: 75, at: 0, settings: settings)
        settings.isEnabled = false
        #expect(engine.evaluate(temperature: 75, at: 1, settings: settings) == nil)
        settings.isEnabled = true
        #expect(engine.evaluate(temperature: 75, at: 2, settings: settings) == nil)
        engine.reset()
        #expect(engine.evaluate(temperature: 75, at: 3, settings: settings) == nil)
        #expect(engine.evaluate(temperature: 75, at: 4, settings: settings) == nil)
        #expect(engine.evaluate(temperature: 75, at: 5, settings: settings) != nil)
    }

    @Test func testClockGoingBackwardsRestartsDuration() {
        var engine = AlertEngine()
        let settings = MonitorSettings()
        _ = engine.evaluate(temperature: 75, at: 10, settings: settings)
        #expect(engine.evaluate(temperature: 75, at: 9, settings: settings) == nil)
        #expect(engine.evaluate(temperature: 75, at: 10, settings: settings) == nil)
        #expect(engine.evaluate(temperature: 75, at: 11, settings: settings) != nil)
    }
}
