import Foundation
import SMCBridge
import TemperatureCore

public struct TemperatureSnapshot: Sendable {
    public let sensors: [TemperatureSensor]
    public let readings: [String: Double]
    public let error: String?
    public let readDuration: TimeInterval
}

/// The connection and its metadata cache are confined to this actor's executor.
public actor SMCReader {
    private var connection: OpaquePointer?
    private var sensors: [TemperatureSensor] = []
    private var nextDiscoveryAt: TimeInterval = 0
    private var keyBuffer = [CChar](repeating: 0, count: 5)
    private var typeBuffer = [CChar](repeating: 0, count: 5)
    private var bytes = [UInt8](repeating: 0, count: 32)

    public init() {}
    deinit { if let connection { sw_smc_close(connection) } }

    public func reset() {
        if let connection { sw_smc_close(connection) }
        connection = nil
        sensors = []
        nextDiscoveryAt = 0
    }

    public func sample(selection: String) -> TemperatureSnapshot {
        let start = ProcessInfo.processInfo.systemUptime
        var error: String?
        if sensors.isEmpty, start >= nextDiscoveryAt {
            nextDiscoveryAt = start + 30
            do { try discover() } catch let failure { error = failure.localizedDescription }
        }
        let selected = SensorSelection.sensors(for: selection, in: sensors)
        var readings: [String: Double] = [:]
        readings.reserveCapacity(selected.count)
        for sensor in selected {
            if let value = read(sensor.id), value > 0, value <= 150 {
                readings[sensor.id] = value
            }
        }
        if error == nil {
            if sensors.isEmpty {
                error = "未找到可用温度传感器；每 30 秒自动重试，也可手动重新检测。"
            } else if selected.isEmpty {
                error = "此 Mac 没有当前选择的传感器，请选择其他监控范围。"
            } else if readings.count != selected.count {
                error = "部分温度传感器读取失败，连续高温计时已中断。"
                if readings.isEmpty {
                    if let connection { sw_smc_close(connection) }
                    connection = nil
                    sensors = []
                    nextDiscoveryAt = start + 30
                }
            }
        }
        return TemperatureSnapshot(
            sensors: sensors, readings: readings, error: error,
            readDuration: ProcessInfo.processInfo.systemUptime - start
        )
    }

    public func allSensors() throws -> TemperatureSnapshot {
        reset()
        try discover()
        return sample(selection: "all-max")
    }

    private func discover() throws {
        if connection == nil {
            var result: Int32 = 0
            connection = sw_smc_open(&result)
            guard connection != nil else {
                throw ReaderError(message: "无法连接 Apple SMC（\(hex(result))）。请确认在真实 Mac 上运行，且应用未启用 App Sandbox。")
            }
        }
        var count: UInt32 = 0
        let result = sw_smc_key_count(connection, &count)
        guard result == 0, count > 0, count <= 50_000 else {
            reset()
            // reset clears retry time; restore backoff for unavailable hardware.
            nextDiscoveryAt = ProcessInfo.processInfo.systemUptime + 30
            throw ReaderError(message: "无法枚举 SMC 传感器（\(hex(result))）。")
        }
        var found: [TemperatureSensor] = []
        for index in 0..<count {
            guard sw_smc_key_at(connection, index, &keyBuffer) == 0,
                  keyBuffer[0] == 84 else { continue } // Only temperature keys.
            let key = String(cString: keyBuffer)
            guard let value = read(key), value > 0, value <= 150 else { continue }
            let group = group(for: key)
            let prefix = group == .cpu ? "CPU" : group == .gpu ? "GPU" : "温度"
            found.append(TemperatureSensor(id: key, name: "\(prefix) · \(key)", group: group))
        }
        sensors = found.sorted { $0.id < $1.id }
    }

    private func read(_ key: String) -> Double? {
        var size: UInt32 = 0
        let result = key.withCString { sw_smc_read(connection, $0, &typeBuffer, &bytes, &size) }
        guard result == 0, size <= 32 else { return nil }
        let type = String(cString: typeBuffer)
        // Enumerating T-prefixed keys is not enough: ignore non-temperature integers,
        // calibration data and status values rather than displaying them as degrees.
        if key.hasPrefix("T"), type != "flt ", !type.hasPrefix("sp") { return nil }
        return SMCValueDecoder.decode(type: type, bytes: Array(bytes.prefix(Int(size))))
    }

    private func group(for key: String) -> SensorGroup {
        #if arch(arm64)
        if key.hasPrefix("Tp") || key.hasPrefix("Te") || (key.hasPrefix("TC") && key != "TCGC") { return .cpu }
        #else
        if key.hasPrefix("TC"), key != "TCGC" { return .cpu }
        #endif
        if key.hasPrefix("Tg") || key.hasPrefix("TG") || key == "TCGC" { return .gpu }
        return .other
    }

    private func hex(_ code: Int32) -> String { String(format: "0x%08x", UInt32(bitPattern: code)) }
}

private struct ReaderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
