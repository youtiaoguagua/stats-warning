import AppKit
import ServiceManagement
import TemperatureIPC
import UserNotifications
import TemperatureCore
import TemperatureHardware

@MainActor
final class MonitorModel {
    private(set) var settings: MonitorSettings
    private(set) var sensors: [TemperatureSensor] = []
    private(set) var temperature: Double?
    private(set) var sensorError: String?
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var message: String?
    private(set) var elapsed: TimeInterval = 0
    private(set) var isLatched = false
    private(set) var lastAlert: Date?
    private(set) var launchAtLogin = false
    private(set) var loginRequiresApproval = false
    private(set) var sampleTime: TimeInterval = 0
    private(set) var isTestingNotification = false

    var onStatusChange: (() -> Void)?
    let notifications = NotificationService()
    private let reader = SMCReader()
    private var engine = AlertEngine()
    private var history = TemperatureHistory()
    private var timer: DispatchSourceTimer?
    private var samplingInFlight = false
    private var notificationInFlight = false
    private var isSleeping = false
    private var generation: UInt64 = 0
    private var observers: [NSObjectProtocol] = []
    private var historyEpoch = UUID()
    private var revision: UInt64 = 0
    private let preferencesKey = "monitor-settings-v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: preferencesKey),
           let saved = try? JSONDecoder().decode(MonitorSettings.self, from: data) {
            settings = saved.validated()
        } else { settings = MonitorSettings() }
        refreshLoginStatus()
    }

    var selectionLabel: String { SensorSelection.label(for: settings.sensorID, in: sensors) }
    func historyPoints(in window: TimeInterval) -> [TemperaturePoint] {
        history.points(in: window, endingAt: sampleTime)
    }

    func clearHistory() {
        history.clear()
        historyEpoch = UUID()
        // Push an update without touching the sampling timer.
        sampleTime = ProcessInfo.processInfo.systemUptime
        publish()
    }
    var notificationAllowed: Bool { notificationStatus == .authorized || notificationStatus == .provisional }
    var stateLabel: String {
        if !settings.isEnabled { return "提醒已暂停" }
        if sensorError != nil { return "传感器不可用" }
        if temperature == nil { return "正在读取温度" }
        if isLatched {
            return message?.hasPrefix("高温条件已满足") == true ? "高温 · 通知未发送" : "已提醒 · 等待降温"
        }
        if elapsed > 0 || (temperature ?? 0) >= settings.threshold { return "持续高温计时中" }
        return "监控中"
    }

    func start() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleep() }
        })
        observers.append(workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.wake() }
        })
        scheduleTimer()
        Task { await refreshAuthorization() }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        generation &+= 1
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    func update(_ mutation: (inout MonitorSettings) -> Void) {
        let previous = settings
        let oldInterval = settings.sampleInterval
        let oldSelection = settings.sensorID
        var changed = settings
        mutation(&changed)
        changed = changed.validated()
        guard changed != settings else { return }
        settings = changed
        if oldSelection != changed.sensorID { clearHistory() }
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: preferencesKey) }
        var monitoringSettings = changed
        monitoringSettings.showsMenuBarItem = previous.showsMenuBarItem
        monitoringSettings.menuBarIcon = previous.menuBarIcon
        monitoringSettings.menuBarDisplay = previous.menuBarDisplay
        if monitoringSettings == previous {
            // Appearance changes must not restart sampling or interrupt a hot episode.
            publish()
            return
        }
        generation &+= 1
        engine.reset()
        elapsed = 0
        isLatched = false
        temperature = nil
        if oldInterval != settings.sampleInterval { scheduleTimer() }
        publish()
        Task { await sample() }
    }

    func refreshAuthorization() async {
        notificationStatus = await notifications.authorization()
        refreshLoginStatus()
        publish()
    }

    func allowNotifications() {
        Task {
            do { _ = try await notifications.requestAuthorization(); message = nil }
            catch { message = error.localizedDescription }
            await refreshAuthorization()
        }
    }

    func testNotification() {
        guard !isTestingNotification else { return }
        isTestingNotification = true
        publish()
        Task {
            defer { isTestingNotification = false; publish() }
            do {
                // Read current system authorization instead of trusting a cached UI value.
                await refreshAuthorization()
                if notificationStatus == .notDetermined { _ = try await notifications.requestAuthorization() }
                await refreshAuthorization()
                try await notifications.send(title: "温度提醒 · 测试通知", body: "通知已就绪。温度连续达到设置的阈值后，将在这里提醒你。", sound: settings.playsSound)
                message = await notifications.testDeliveryMessage()
            } catch { message = error.localizedDescription }
        }
    }

    func rescan() {
        generation &+= 1
        engine.reset()
        elapsed = 0
        temperature = nil
        isLatched = false
        history.breakContinuity()
        publish()
        Task {
            await reader.reset()
            await sample()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            message = nil
        } catch { message = "无法设置登录启动：\(error.localizedDescription)" }
        refreshLoginStatus()
        publish()
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    func makeState(includeHistory: Bool = false) -> MonitorState {
        var state = MonitorState(settings: settings)
        state.revision = revision
        state.temperature = temperature
        state.sensorError = sensorError
        state.sensorCount = SensorSelection.sensors(for: settings.sensorID, in: sensors).count
        state.selectionLabel = selectionLabel
        state.stateLabel = stateLabel
        state.elapsed = elapsed
        state.isLatched = isLatched
        state.lastAlert = lastAlert
        state.notificationAuthorization = notificationStatus.rawValue
        state.launchAtLogin = launchAtLogin
        state.loginRequiresApproval = loginRequiresApproval
        state.message = message
        state.isTestingNotification = isTestingNotification
        state.sampleTime = sampleTime
        state.historyEpoch = historyEpoch
        state.latestPoint = history.latestPoint
        if includeHistory { state.history = historyPoints(in: TemperatureHistory.retention) }
        return state
    }

    private func publish() {
        revision &+= 1
        onStatusChange?()
    }

    private func refreshLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        loginRequiresApproval = status == .requiresApproval
    }

    private func scheduleTimer() {
        timer?.cancel()
        guard !isSleeping else { return }
        let interval = settings.sampleInterval
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(min(100, interval * 100))))
        source.setEventHandler { [weak self] in
            Task { @MainActor in await self?.sample() }
        }
        timer = source
        source.resume()
    }

    private func sample() async {
        guard !samplingInFlight, !isSleeping else { return }
        samplingInFlight = true
        defer { samplingInFlight = false }
        let sampleGeneration = generation
        let snapshot = await reader.sample(selection: settings.sensorID)
        guard sampleGeneration == generation, !isSleeping else { return }
        if sensors != snapshot.sensors { sensors = snapshot.sensors }
        sensorError = snapshot.error
        temperature = SensorSelection.temperature(for: settings.sensorID, sensors: snapshot.sensors, readings: snapshot.readings)
        let now = ProcessInfo.processInfo.systemUptime
        history.append(temperature: temperature, at: now, sampleInterval: settings.sampleInterval)
        sampleTime = now
        let event = engine.evaluate(temperature: temperature, at: now, settings: settings)
        elapsed = engine.elapsed(at: now)
        isLatched = engine.isLatched
        publish()
        if let event, !notificationInFlight {
            notificationInFlight = true
            let rule = settings
            let source = selectionLabel
            Task {
                defer { notificationInFlight = false }
                do {
                    try await notifications.send(
                        title: "Mac 温度过高 · \(String(format: "%.1f", event.temperature))°C",
                        body: "\(source)连续 \(String(format: "%.1f", event.elapsed)) 秒达到 \(String(format: "%.0f", rule.threshold))°C。",
                        sound: rule.playsSound
                    )
                    lastAlert = Date()
                    message = nil
                } catch { message = "高温条件已满足，但提醒未发送：\(error.localizedDescription)" }
                await refreshAuthorization()
            }
        }
    }

    private func sleep() {
        isSleeping = true
        timer?.cancel()
        timer = nil
        generation &+= 1
        engine.reset()
        elapsed = 0
        isLatched = false
        temperature = nil
        history.breakContinuity()
        publish()
    }

    private func wake() {
        isSleeping = false
        generation &+= 1
        engine.reset()
        scheduleTimer()
    }
}
