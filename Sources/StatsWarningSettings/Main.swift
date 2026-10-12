import AppKit

@main
enum SettingsMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = SettingsAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class SettingsAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var model: SettingsModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--endpoint"), index + 1 < arguments.count else {
            let alert = NSAlert()
            alert.messageText = "请从温度提醒打开设置"
            alert.informativeText = "点击菜单栏温度，或重新打开 StatsWarning.app。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let model = SettingsModel(endpointURL: URL(fileURLWithPath: arguments[index + 1]))
        self.model = model
        var initialSize = SettingsLayout.defaultSize
        if let visible = NSScreen.main?.visibleFrame {
            initialSize.width = min(initialSize.width, max(SettingsLayout.minimumSize.width, visible.width - 48))
            initialSize.height = min(initialSize.height, max(SettingsLayout.minimumSize.height, visible.height - 48))
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: initialSize),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "温度提醒设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = SettingsViewController(model: model)
        window.contentMinSize = SettingsLayout.minimumSize
        window.setContentSize(initialSize)
        // Keep native layout sizing separate from the previous SwiftUI frame.
        if !window.setFrameUsingName("SettingsWindowAppKitV1") { window.center() }
        window.contentMinSize = SettingsLayout.minimumSize
        window.setFrameAutosaveName("SettingsWindowAppKitV1")
        self.window = window
        model.connect()
        showWindow()
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        model?.refreshAuthorization()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Refresh once on return from System Settings; no status polling timer.
        model?.refreshAuthorization()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.isConnected == true,
              let controller = window?.contentViewController as? SettingsViewController else { return .terminateNow }
        DispatchQueue.main.async {
            controller.prepareToClose { saved in sender.reply(toApplicationShouldTerminate: saved) }
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { model?.disconnect() }
}
