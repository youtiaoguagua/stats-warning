import AppKit
import Foundation
import TemperatureHardware
import TemperatureCore

@main
enum StatsWarningMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--probe") || CommandLine.arguments.contains("--benchmark") {
            runDiagnostics()
            dispatchMain()
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            fputs("Please run scripts/build-app.sh and open dist/StatsWarning.app. Use --probe for CLI diagnostics.\n", stderr)
            exit(1)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private static func runDiagnostics() {
        Task.detached(priority: .utility) {
            do {
                let reader = SMCReader()
                let initial = try await reader.allSensors()
                guard !initial.sensors.isEmpty else {
                    fputs("No usable temperature sensors found.\n", stderr)
                    exit(1)
                }
                if CommandLine.arguments.contains("--probe") {
                    let rows = initial.sensors.map { sensor in
                        ["key": sensor.id, "group": sensor.group.rawValue,
                         "celsius": initial.readings[sensor.id].map { $0 as Any } ?? NSNull()] as [String: Any]
                    }
                    let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                    exit(initial.error == nil ? 0 : 1)
                }
                let args = CommandLine.arguments
                func argument(_ name: String, fallback: Double) -> Double {
                    guard let index = args.firstIndex(of: name), index + 1 < args.count,
                          let value = Double(args[index + 1]), value.isFinite else { return fallback }
                    return value
                }
                let interval = min(60, max(0.5, argument("--interval", fallback: 1)))
                let seconds = min(120, max(1, argument("--seconds", fallback: 15)))
                let start = ProcessInfo.processInfo.systemUptime
                var durations: [Double] = []
                repeat {
                    let result = await reader.sample(selection: "cpu-max")
                    guard result.error == nil else { throw DiagnosticError(message: result.error!) }
                    durations.append(result.readDuration * 1_000)
                    try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                } while ProcessInfo.processInfo.systemUptime - start < seconds
                let summary: [String: Any] = [
                    "samples": durations.count,
                    "interval_seconds": interval,
                    "selected_sensors": SensorSelection.sensors(for: "cpu-max", in: initial.sensors).count,
                    "average_read_ms": durations.reduce(0, +) / Double(durations.count),
                    "max_read_ms": durations.max() ?? 0
                ]
                let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                exit(0)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
    }
}

private struct DiagnosticError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
