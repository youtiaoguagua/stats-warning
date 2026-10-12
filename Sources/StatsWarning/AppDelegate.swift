import AppKit
import CoreServices
import TemperatureCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var model: MonitorModel?
    private var server: MonitorServer?
    private var renderedSymbol: String?
    private var openingSettings = false
    private var settingsURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/StatsWarningSettings.app")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // One monitor owns the SMC sampler and the notification identity.
        let owner = NSRunningApplication.runningApplications(withBundleIdentifier: "io.local.stats-warning")
            .filter { !$0.isTerminated }
            .min {
                let left = $0.launchDate ?? .distantPast
                let right = $1.launchDate ?? .distantPast
                return left == right ? $0.processIdentifier < $1.processIdentifier : left < right
            }
        if let owner, owner.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: owner.bundleURL ?? Bundle.main.bundleURL, configuration: configuration) { _, _ in }
            NSApp.terminate(nil)
            return
        }
        let model = MonitorModel()
        self.model = model
        do { server = try MonitorServer(model: model) }
        catch {
            let alert = NSAlert()
            alert.messageText = "无法启动温度提醒"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(menuBarClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        model.onStatusChange = { [weak self] in
            self?.updateStatus()
            self?.server?.broadcast()
        }
        model.notifications.onOpen = { [weak self] in self?.showSettings() }
        updateStatus()
        model.start()
        let launchEvent = NSAppleEventManager.shared().currentAppleEvent
        let launchKind = launchEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        let automaticLaunch = launchEvent?.eventID == kAEOpenApplication &&
            (launchKind == keyAELaunchedAsLogInItem || launchKind == keyAELaunchedAsServiceItem)
        // A manual launch must provide an entry point when the menu bar is hidden.
        // Login / service launches remain in the background after onboarding.
        if CommandLine.arguments.contains("--show-settings") || !UserDefaults.standard.bool(forKey: "did-open-onboarding") ||
            (!automaticLaunch && !model.settings.showsMenuBarItem) {
            showSettings()
            UserDefaults.standard.set(true, forKey: "did-open-onboarding")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard model != nil else { return }
        model?.stop()
        server?.stop()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "io.local.stats-warning.settings")
            where app.bundleURL?.standardizedFileURL == settingsURL.standardizedFileURL {
            app.terminate()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    private func updateStatus() {
        guard let model else { return }
        let settings = model.settings
        if !settings.showsMenuBarItem {
            if statusItem.isVisible { statusItem.isVisible = false }
            return
        }
        if !statusItem.isVisible { statusItem.isVisible = true }
        guard let button = statusItem.button else { return }
        let symbol = settings.menuBarDisplay.showsIcon ? settings.menuBarIcon.symbolName : ""
        if renderedSymbol != symbol {
            button.image = symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: "温度提醒")
            button.image?.isTemplate = true
            renderedSymbol = symbol
        }
        let temperature = model.temperature.map { String(format: "%.0f°", $0) } ?? "—°"
        let title = settings.menuBarDisplay.showsTemperature ? (symbol.isEmpty ? temperature : " " + temperature) : ""
        if button.title != title { button.title = title }
        button.appearsDisabled = !settings.isEnabled
        button.toolTip = "温度提醒 · \(temperature) · \(model.selectionLabel) · \(model.stateLabel)"
        button.setAccessibilityLabel(button.toolTip)
    }

    @objc private func menuBarClicked() {
        guard let model else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: model.settings.isEnabled ? "暂停提醒" : "启用提醒", action: #selector(toggleMonitoring), keyEquivalent: "")
            menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出温度提醒", action: #selector(quit), keyEquivalent: "q")
            for item in menu.items { item.target = self }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else { showSettings() }
    }

    private func showSettings() {
        guard let server, !openingSettings else { return }
        openingSettings = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = ["--endpoint", server.endpointURL.path]
        NSWorkspace.shared.openApplication(at: settingsURL, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                self?.openingSettings = false
                if let error {
                    let alert = NSAlert()
                    alert.messageText = "无法打开设置"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    @objc private func toggleMonitoring() { model?.update { $0.isEnabled.toggle() } }
    @objc private func openSettings() { showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
}
