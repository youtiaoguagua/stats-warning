import Foundation
import Testing
@testable import TemperatureCore

struct SensorTests {
    private let sensors = [
        TemperatureSensor(id: "Tp01", name: "CPU", group: .cpu),
        TemperatureSensor(id: "Te01", name: "CPU", group: .cpu),
        TemperatureSensor(id: "Tg01", name: "GPU", group: .gpu)
    ]

    @Test func testSelectionReadsOnlyRequestedGroup() {
        #expect(SensorSelection.sensors(for: "cpu-max", in: sensors).map(\.id) == ["Tp01", "Te01"])
        #expect(SensorSelection.sensors(for: "Tg01", in: sensors).map(\.id) == ["Tg01"])
        #expect(SensorSelection.temperature(for: "missing", sensors: sensors, readings: ["Tp01": 75]) == nil)
    }

    @Test func testMaximumNeverUsesPartialReadings() {
        #expect(SensorSelection.temperature(for: "cpu-max", sensors: sensors, readings: ["Tp01": 50]) == nil)
        #expect(SensorSelection.temperature(for: "cpu-max", sensors: sensors, readings: ["Tp01": 50, "Te01": 75, "Tg01": 95]) == 75)
        #expect(SensorSelection.temperature(for: "cpu-max", sensors: sensors, readings: ["Tp01": .nan, "Te01": 75]) == nil)
    }

    @Test func cpuAverageExcludesOtherSensorsAndCPUProximity() {
        let discovered = sensors + [
            TemperatureSensor(id: "TCMb", name: "CPU proximity", group: .cpu),
            TemperatureSensor(id: "TCHP", name: "CPU heatsink", group: .cpu)
        ]
        let readings = ["Tp01": 50.0, "Te01": 80.0, "Tg01": 95.0, "TCMb": 99.0, "TCHP": 100.0]
        #expect(SensorSelection.sensors(for: "cpu-average", in: discovered).map(\.id) == ["Tp01", "Te01"])
        #expect(SensorSelection.temperature(for: "cpu-average", sensors: discovered, readings: readings) == 65)
        #expect(SensorSelection.temperature(for: "cpu-max", sensors: discovered, readings: readings) == 100)
    }

    @Test func cpuAverageRejectsPartialInvalidAndEmptyReadings() {
        #expect(SensorSelection.temperature(for: "cpu-average", sensors: sensors, readings: ["Tp01": 50]) == nil)
        for invalid in [Double.nan, .infinity, -1, 151] {
            #expect(SensorSelection.temperature(for: "cpu-average", sensors: sensors, readings: ["Tp01": 50, "Te01": invalid]) == nil)
        }
        #expect(SensorSelection.temperature(for: "cpu-average", sensors: [], readings: [:]) == nil)
        let proximity = [TemperatureSensor(id: "TC0P", name: "CPU proximity", group: .cpu)]
        #expect(SensorSelection.temperature(for: "cpu-average", sensors: proximity, readings: ["TC0P": 80]) == nil)
    }

    @Test func intelCoreAverageExcludesPackageAndIntegratedGPU() {
        let discovered = [
            TemperatureSensor(id: "TC0c", name: "Core 1", group: .cpu),
            TemperatureSensor(id: "TC1C", name: "Core 2", group: .cpu),
            TemperatureSensor(id: "TCAD", name: "Package", group: .cpu),
            TemperatureSensor(id: "TCGC", name: "Integrated GPU", group: .gpu)
        ]
        #expect(SensorSelection.temperature(for: "cpu-average", sensors: discovered,
            readings: ["TC0c": 60, "TC1C": 80, "TCAD": 99, "TCGC": 100]) == 70)
    }

    @Test func testSignedFixedPointDecode() {
        #expect(SMCValueDecoder.decode(type: "sp78", bytes: [70, 128]) == 70.5)
        #expect(SMCValueDecoder.decode(type: "sp78", bytes: [255, 128]) == -0.5)
        #expect(SMCValueDecoder.decode(type: "sp78", bytes: [70]) == nil)
    }

    @Test func testLittleEndianFloatDecodeAndInvalidData() {
        #expect(SMCValueDecoder.decode(type: "flt ", bytes: [0, 0, 140, 66]) == 70)
        #expect(SMCValueDecoder.decode(type: "flt ", bytes: [0, 0, 128, 127]) == nil)
        #expect(SMCValueDecoder.decode(type: "flt ", bytes: [0, 0, 140]) == nil)
        #expect(SMCValueDecoder.decode(type: "????", bytes: [70, 0]) == nil)
        #expect(SMCValueDecoder.decode(type: "ui32", bytes: [0, 0, 1, 0]) == 256)
    }

    @Test func testSettingsPersistAndValidateCorruptValues() throws {
        var settings = MonitorSettings()
        settings.sampleInterval = 5
        let restored = try JSONDecoder().decode(MonitorSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored == settings)
        settings.threshold = .nan
        settings.sampleInterval = 0
        settings.duration = -.infinity
        settings.cooldown = -10
        let safe = settings.validated()
        #expect(safe.threshold == 70)
        #expect(safe.sampleInterval == 0.5)
        #expect(safe.duration == 2)
        #expect(safe.cooldown == 0)
    }

    @Test func retiredScopesMigrateWithoutChangingOtherPreferences() throws {
        for selection in ["all-max", "Tp01", "", "unknown", "cpu-max", "cpu-average", "gpu-max"] {
            var settings = MonitorSettings()
            settings.sensorID = selection
            settings.threshold = 85
            settings.sampleInterval = 5
            settings.menuBarIcon = .flame
            let restored = try JSONDecoder().decode(MonitorSettings.self, from: JSONEncoder().encode(settings)).validated()
            var expected = settings
            expected.sensorID = MonitorScope(rawValue: selection)?.rawValue ?? "cpu-max"
            #expect(restored == expected)
        }
    }
}
