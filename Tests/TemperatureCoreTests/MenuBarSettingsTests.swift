import Foundation
import Testing
@testable import TemperatureCore

struct MenuBarSettingsTests {
    @Test func upgradesExistingRulesWithoutLosingUserValues() throws {
        let oldPreferences = Data(#"{"threshold":85,"duration":4,"sampleInterval":5,"cooldown":120,"hysteresis":2,"sensorID":"gpu-max","isEnabled":false,"playsSound":false}"#.utf8)
        let settings = try JSONDecoder().decode(MonitorSettings.self, from: oldPreferences)
        #expect(settings.threshold == 85)
        #expect(settings.duration == 4)
        #expect(settings.sampleInterval == 5)
        #expect(settings.cooldown == 120)
        #expect(settings.hysteresis == 2)
        #expect(settings.sensorID == "gpu-max")
        #expect(!settings.isEnabled && !settings.playsSound)
        #expect(settings.showsMenuBarItem)
        #expect(settings.menuBarIcon == .thermometer)
        #expect(settings.menuBarDisplay == .iconAndTemperature)
    }

    @Test func retainsHiddenItemAndAppearanceAcrossRestart() throws {
        var settings = MonitorSettings()
        settings.showsMenuBarItem = false
        settings.menuBarIcon = .flame
        settings.menuBarDisplay = .temperatureOnly
        let restored = try JSONDecoder().decode(MonitorSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
    }

    @Test func unknownAppearanceValuesKeepMonitoringRules() throws {
        let preferences = Data(#"{"threshold":90,"sampleInterval":10,"menuBarIcon":"future-icon","menuBarDisplay":"future-display"}"#.utf8)
        let restored = try JSONDecoder().decode(MonitorSettings.self, from: preferences)
        #expect(restored.threshold == 90)
        #expect(restored.sampleInterval == 10)
        #expect(restored.menuBarIcon == .thermometer)
        #expect(restored.menuBarDisplay == .iconAndTemperature)
    }
}
