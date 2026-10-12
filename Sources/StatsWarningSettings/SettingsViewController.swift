import AppKit
import TemperatureCore

@MainActor
final class SettingsViewController: NSViewController, NSTextFieldDelegate {
    private let model: SettingsModel
    private let enabled = NSSwitch()
    private let temperature = label("—", size: 44, weight: .medium)
    private let status = label("正在连接监控", size: 12)
    private let statusDot = NSImageView()
    private let lastAlert = label("", size: 12)
    private let progress = NSProgressIndicator()
    private let progressText = label("", size: 12)
    private var progressRow: NSStackView!
    private let chart = TemperatureChartView()
    private let range = NSSegmentedControl(labels: ["1分", "5分", "10分"], trackingMode: .selectOne, target: nil, action: nil)
    private let extremes = label("等待采样", size: 12)
    private let reminder = label("提醒线 70°C", size: 12)
    private let scope = NSPopUpButton()
    private let threshold = numberField("阈值", value: "70")
    private let duration = numberField("持续", value: "2")
    private let interval = numberField("采样间隔", value: "1")
    private let cooldown = numberField("提醒间隔", value: "60")
    private let hysteresis = numberField("降温重置幅度", value: "3")
    private let samplingMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    private let slowSampling = label("采样较慢，提醒会延迟至后续采样点。", size: 12)
    private let feedback = wrappingLabel()
    private let saveStatus = label("自动保存", size: 12)
    private let more = NSButton()
    private let showMenu = NSButton(checkboxWithTitle: "显示在菜单栏", target: nil, action: nil)
    private let icon = NSPopUpButton()
    private let display = NSPopUpButton()
    private let sound = NSButton(checkboxWithTitle: "通知提示音", target: nil, action: nil)
    private let login = NSButton(checkboxWithTitle: "开机自启", target: nil, action: nil)
    private let loginStatus = label("已关闭", size: 12)
    private let loginDescription = wrappingLabel()
    private var advanced: NSStackView!
    private var permissionRow: NSStackView!
    private let allow = NSButton()
    private let notices = wrappingLabel()
    private let reconnect = NSButton()
    private let test = NSButton()
    private let sampleInfo = label("", size: 12)
    private var connectedControls: [NSControl] = []
    private var draftsLoaded = false
    private var chartWindow: TimeInterval = 60
    private var autosaveTask: Task<Void, Never>?
    private var editRevision: UInt64 = 0
    private var pendingRuleSaves = 0
    private var saveFailed = false
    private var closeAfterSaving: ((Bool) -> Void)?

    init(model: SettingsModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = SettingsLayout.defaultSize
    }
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: SettingsLayout.defaultSize))
        root.autoresizingMask = [.width, .height]
        view = root
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: SettingsLayout.minimumSize.width),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsLayout.minimumSize.height)
        ])
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        let content = vertical(spacing: 18)
        document.addSubview(content)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        func section(_ item: NSView) {
            item.translatesAutoresizingMaskIntoConstraints = false
            content.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        let thermometer = NSImageView(image: NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "温度提醒")!)
        thermometer.contentTintColor = .systemOrange
        thermometer.widthAnchor.constraint(equalToConstant: 24).isActive = true
        thermometer.heightAnchor.constraint(equalToConstant: 28).isActive = true
        enabled.target = self; enabled.action = #selector(enabledChanged)
        enabled.setAccessibilityLabel("启用高温提醒")
        enabled.toolTip = "暂停提醒后，后台继续采样。"
        section(horizontal([thermometer, label("温度提醒", size: 18, weight: .semibold), spacer(), enabled]))
        connectedControls.append(enabled)

        temperature.font = .monospacedDigitSystemFont(ofSize: 44, weight: .medium)
        statusDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        statusDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let statusColumn = vertical([horizontal([statusDot, status], spacing: 6), lastAlert], spacing: 5)
        statusColumn.alignment = .trailing
        progress.style = .bar; progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1
        progressRow = horizontal([progress, progressText], spacing: 10)
        progress.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let readings = vertical([horizontal([temperature, label("°C", size: 16), spacer(), statusColumn], spacing: 5), progressRow], spacing: 8)
        for item in readings.arrangedSubviews { item.widthAnchor.constraint(equalTo: readings.widthAnchor).isActive = true }
        let card = RoundedCardView()
        card.addSubview(readings)
        NSLayoutConstraint.activate([
            readings.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            readings.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            readings.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            readings.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        section(card)

        login.target = self; login.action = #selector(loginChanged)
        connectedControls.append(login)
        loginStatus.textColor = .secondaryLabelColor
        loginDescription.textColor = .secondaryLabelColor
        let startup = vertical([
            horizontal([login, loginStatus, spacer(), button("登录项设置…", action: #selector(openLoginSettings))]),
            loginDescription
        ], spacing: 6)
        for item in startup.arrangedSubviews { item.widthAnchor.constraint(equalTo: startup.widthAnchor).isActive = true }
        section(startup)

        range.selectedSegment = 0; range.target = self; range.action = #selector(rangeChanged)
        range.widthAnchor.constraint(equalToConstant: 200).isActive = true
        range.setAccessibilityLabel("曲线时间范围")
        let clear = button("", action: #selector(clearHistory))
        clear.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "清空曲线")
        clear.setAccessibilityLabel("清空曲线"); clear.toolTip = "清空曲线"
        connectedControls.append(clear)
        chart.heightAnchor.constraint(equalToConstant: 180).isActive = true
        reminder.textColor = .systemOrange
        let curve = vertical([
            horizontal([label("温度曲线", size: 15, weight: .semibold), spacer(), range, clear]),
            chart, horizontal([extremes, spacer(), reminder])
        ])
        for item in curve.arrangedSubviews { item.widthAnchor.constraint(equalTo: curve.widthAnchor).isActive = true }
        section(curve)

        saveStatus.textColor = .secondaryLabelColor
        scope.addItems(withTitles: MonitorScope.allCases.map(\.label))
        scope.toolTip = "CPU 平均温度使用本次采样中 CPU 核心传感器的平均值，提醒规则也使用该值。"
        scope.target = self; scope.action = #selector(scopeChanged)
        scope.setAccessibilityLabel("监控范围")
        connectedControls.append(scope)
        for field in [threshold, duration, interval, cooldown, hysteresis] {
            field.delegate = self
            connectedControls.append(field)
        }
        samplingMenu.addItem(withTitle: "采样间隔")
        samplingMenu.isBordered = false
        samplingMenu.setAccessibilityLabel("采样间隔快捷选项")
        for value in [0.5, 1, 2, 5, 10] {
            samplingMenu.addItem(withTitle: "\(value.formatted()) 秒")
            let item = samplingMenu.lastItem!
            item.representedObject = value; item.target = self; item.action = #selector(samplePreset)
        }
        samplingMenu.menu?.autoenablesItems = false
        let samplingRow = horizontal([samplingMenu, spacer(), interval, unit("秒")])
        let numericTop = pair(numeric("阈值", threshold, "°C"), numeric("持续", duration, "秒"))
        let numericBottom = pair(samplingRow, numeric("提醒间隔", cooldown, "秒"))
        let scopeRow = horizontal([label("监控范围"), scope])
        scope.widthAnchor.constraint(equalTo: scopeRow.widthAnchor, constant: -62).isActive = true
        slowSampling.textColor = .systemOrange
        more.title = "▸ 更多设置"; more.isBordered = false
        more.font = .systemFont(ofSize: 13, weight: .semibold)
        more.target = self; more.action = #selector(toggleAdvanced)
        more.setAccessibilityLabel("更多设置")
        showMenu.target = self; showMenu.action = #selector(menuVisibilityChanged)
        for option in MenuBarIcon.allCases {
            icon.addItem(withTitle: option.label)
            icon.lastItem?.image = NSImage(systemSymbolName: option.symbolName, accessibilityDescription: nil)
        }
        display.addItems(withTitles: MenuBarDisplay.allCases.map(\.label))
        icon.target = self; icon.action = #selector(iconChanged)
        display.target = self; display.action = #selector(displayChanged)
        icon.setAccessibilityLabel("菜单栏图标")
        display.setAccessibilityLabel("菜单栏显示模式")
        sound.target = self; sound.action = #selector(soundChanged)
        connectedControls.append(contentsOf: [showMenu, icon, display, sound])
        let iconRow = horizontal([label("图标"), icon])
        let displayRow = horizontal([label("显示"), display])
        icon.widthAnchor.constraint(equalTo: iconRow.widthAnchor, constant: -36).isActive = true
        display.widthAnchor.constraint(equalTo: displayRow.widthAnchor, constant: -36).isActive = true
        advanced = vertical([
            showMenu,
            pair(iconRow, displayRow),
            label("隐藏后仍会监控。重新打开应用即可设置。", size: 12),
            numeric("降温重置幅度", hysteresis, "°C"),
            sound,
            label("同一次高温只提醒一次，降温后重新计时。", size: 12),
            button("通知设置…", action: #selector(openNotificationSettings))
        ])
        for item in advanced.arrangedSubviews where !(item is NSButton) { item.widthAnchor.constraint(equalTo: advanced.widthAnchor).isActive = true }
        advanced.isHidden = true
        feedback.textColor = .systemOrange
        let rules = vertical([
            horizontal([label("提醒规则", size: 15, weight: .semibold), spacer(), saveStatus]),
            scopeRow, numericTop, numericBottom,
            slowSampling, more, advanced, feedback
        ])
        for item in rules.arrangedSubviews where item !== more {
            item.widthAnchor.constraint(equalTo: rules.widthAnchor).isActive = true
        }
        scope.setContentHuggingPriority(.defaultLow, for: .horizontal)
        icon.setContentHuggingPriority(.defaultLow, for: .horizontal)
        display.setContentHuggingPriority(.defaultLow, for: .horizontal)
        section(rules)
        configure(allow, title: "允许通知", action: #selector(allowNotifications))
        permissionRow = vertical([
            label("需要允许 macOS 通知", size: 12),
            horizontal([allow, button("通知设置", action: #selector(openNotificationSettings)), spacer()])
        ])
        section(permissionRow)
        section(notices)
        configure(reconnect, title: "重新连接", action: #selector(reconnectMonitor))
        section(reconnect)

        configure(test, title: "测试通知", action: #selector(testNotification))
        let rescan = button("重新检测", action: #selector(rescanSensors))
        let quit = button("退出监控", action: #selector(quitMonitor))
        connectedControls.append(contentsOf: [test, rescan, quit, samplingMenu])
        sampleInfo.textColor = .secondaryLabelColor
        let footer = vertical([horizontal([test, rescan, spacer(), quit]), sampleInfo], spacing: 10)
        footer.arrangedSubviews[0].widthAnchor.constraint(equalTo: footer.widthAnchor).isActive = true
        footer.setContentHuggingPriority(.required, for: .vertical)
        let divider = NSBox(); divider.boxType = .separator
        for item in [scroll, divider, footer] { item.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(item) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: divider.topAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor), divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            footer.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 16),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        model.onChange = { [weak self] in self?.render() }
        render()
    }

    private func render() {
        if model.isConnected && !draftsLoaded { loadDrafts(); draftsLoaded = true }
        for control in connectedControls { control.isEnabled = model.isConnected }
        test.isEnabled = model.isConnected && !model.isTestingNotification
        enabled.state = model.settings.isEnabled ? .on : .off
        let hot = (model.temperature ?? 0) >= model.settings.threshold
        temperature.stringValue = model.temperature.map { String(format: "%.1f", $0) } ?? "—"
        temperature.textColor = hot ? .systemOrange : .labelColor
        status.stringValue = model.stateLabel
        statusDot.contentTintColor = !model.settings.isEnabled ? .secondaryLabelColor : (model.sensorError != nil || hot ? .systemOrange : .systemGreen)
        lastAlert.stringValue = model.lastAlert.map { "上次提醒 \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        lastAlert.isHidden = model.lastAlert == nil
        progressRow.isHidden = model.elapsed <= 0 || model.isLatched
        progress.doubleValue = min(1, model.elapsed / model.settings.duration)
        progressText.stringValue = String(format: "%.1f / %.1f 秒", model.elapsed, model.settings.duration)
        chart.update(points: model.historyPoints(in: chartWindow), window: chartWindow, now: model.sampleTime, threshold: model.settings.threshold)
        extremes.stringValue = chart.minimum.map { String(format: "最低 %.1f°C   最高 %.1f°C", $0, chart.maximum ?? $0) } ?? "等待采样"
        reminder.stringValue = String(format: "提醒线 %.0f°C", model.settings.threshold)
        scope.selectItem(at: MonitorScope.allCases.firstIndex(where: { $0.rawValue == model.settings.sensorID }) ?? 0)
        showMenu.state = model.settings.showsMenuBarItem ? .on : .off
        icon.selectItem(at: MenuBarIcon.allCases.firstIndex(of: model.settings.menuBarIcon) ?? 0)
        display.selectItem(at: MenuBarDisplay.allCases.firstIndex(of: model.settings.menuBarDisplay) ?? 0)
        sound.state = model.settings.playsSound ? .on : .off
        login.state = model.launchAtLogin || model.loginRequiresApproval ? .on : .off
        login.isEnabled = model.isConnected && !model.isUpdatingLogin
        loginStatus.stringValue = model.isUpdatingLogin ? "正在更新…" :
            (model.loginRequiresApproval ? "等待系统批准" : (model.launchAtLogin ? "已启用" : "已关闭"))
        loginStatus.textColor = model.loginRequiresApproval ? .systemOrange : .secondaryLabelColor
        loginDescription.stringValue = model.loginRequiresApproval
            ? "请在「登录项设置」中允许温度提醒运行。"
            : "登录 Mac 后自动在后台监控，设置窗口不会自动打开。"
        permissionRow.isHidden = !model.isConnected || model.notificationAllowed
        allow.isHidden = model.notificationStatus != .notDetermined
        var messages: [String] = []
        for text in [model.sensorError, model.message].compactMap({ $0 }) where !messages.contains(text) { messages.append(text) }
        notices.stringValue = messages.joined(separator: "\n")
        notices.isHidden = messages.isEmpty
        reconnect.isHidden = model.isConnected || model.connectionError == nil
        sampleInfo.stringValue = String(format: "每 %.1fs 采样 · %d 个传感器", model.settings.sampleInterval, model.sensorCount)
        updateDraftWarning()
    }

    private func loadDrafts() {
        for (field, value) in [(threshold, model.settings.threshold), (duration, model.settings.duration),
                               (interval, model.settings.sampleInterval), (cooldown, model.settings.cooldown), (hysteresis, model.settings.hysteresis)] {
            field.stringValue = String(format: "%g", value)
        }
    }
    private func number(_ field: NSTextField) -> Double? {
        Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }
    private func updateDraftWarning() {
        slowSampling.isHidden = !(number(interval).map { $0 > (number(duration) ?? .infinity) } ?? false)
        feedback.isHidden = feedback.stringValue.isEmpty
    }
    func controlTextDidChange(_ obj: Notification) { scheduleRuleSave() }
    func controlTextDidEndEditing(_ obj: Notification) { saveRuleChanges() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            view.window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    private var ruleFields: [(NSTextField, WritableKeyPath<MonitorSettings, Double>, ClosedRange<Double>, String)] {
        [(threshold, \.threshold, 30...120, "阈值需为 30–120°C"),
         (duration, \.duration, 0.5...600, "持续时间需为 0.5–600 秒"),
         (interval, \.sampleInterval, 0.5...60, "采样间隔需为 0.5–60 秒"),
         (cooldown, \.cooldown, 0...3600, "提醒间隔需为 0–3600 秒"),
         (hysteresis, \.hysteresis, 0...10, "降温重置幅度需为 0–10°C")]
    }

    private func scheduleRuleSave() {
        editRevision &+= 1
        autosaveTask?.cancel()
        saveStatus.stringValue = "待保存…"
        feedback.stringValue = ""
        updateDraftWarning()
        // One cancellable delay during editing; no idle or background timer.
        autosaveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 400_000_000) }
            catch { return }
            self?.saveRuleChanges()
        }
    }

    private func saveRuleChanges() {
        autosaveTask?.cancel()
        autosaveTask = nil
        guard draftsLoaded, model.isConnected else { return }
        var changes: [(WritableKeyPath<MonitorSettings, Double>, Double)] = []
        var errors: [String] = []
        for (field, key, range, hint) in ruleFields {
            guard let value = number(field), value.isFinite, range.contains(value) else {
                errors.append(hint + "，此项未保存。")
                continue
            }
            if value != model.settings[keyPath: key] { changes.append((key, value)) }
        }
        feedback.stringValue = errors.joined(separator: "\n")
        updateDraftWarning()
        guard !changes.isEmpty else {
            if pendingRuleSaves == 0 { saveStatus.stringValue = errors.isEmpty ? "已自动保存" : "部分输入无效" }
            return
        }
        let revision = editRevision
        pendingRuleSaves += 1
        saveFailed = false
        saveStatus.stringValue = "正在保存…"
        model.updateRules({ settings in
            for (key, value) in changes { settings[keyPath: key] = value }
        }) { [weak self] saved in
            guard let self else { return }
            self.pendingRuleSaves -= 1
            if !saved { self.saveFailed = true }
            if revision == self.editRevision {
                self.saveStatus.stringValue = saved ? (errors.isEmpty ? "已自动保存" : "部分输入无效") : "保存失败"
                if !saved { self.feedback.stringValue = "自动保存失败，请查看连接提示。" }
                self.updateDraftWarning()
            }
            if self.pendingRuleSaves == 0, let completion = self.closeAfterSaving {
                self.closeAfterSaving = nil
                completion(!self.saveFailed)
            }
        }
    }

    func prepareToClose(_ completion: @escaping (Bool) -> Void) {
        view.window?.makeFirstResponder(nil)
        saveRuleChanges()
        // Wait for the monitor's acknowledgement before ending the UI process.
        if pendingRuleSaves == 0 { completion(!saveFailed) }
        else { closeAfterSaving = completion }
    }
    @objc private func enabledChanged() { model.update { $0.isEnabled = enabled.state == .on } }
    @objc private func scopeChanged() {
        guard MonitorScope.allCases.indices.contains(scope.indexOfSelectedItem) else { return }
        model.update { $0.sensorID = MonitorScope.allCases[scope.indexOfSelectedItem].rawValue }
    }
    @objc private func menuVisibilityChanged() { model.update { $0.showsMenuBarItem = showMenu.state == .on } }
    @objc private func iconChanged() { model.update { $0.menuBarIcon = MenuBarIcon.allCases[icon.indexOfSelectedItem] } }
    @objc private func displayChanged() { model.update { $0.menuBarDisplay = MenuBarDisplay.allCases[display.indexOfSelectedItem] } }
    @objc private func soundChanged() { model.update { $0.playsSound = sound.state == .on } }
    @objc private func loginChanged() { model.setLaunchAtLogin(login.state == .on) }
    @objc private func samplePreset(_ item: NSMenuItem) {
        if let value = item.representedObject as? Double {
            view.window?.makeFirstResponder(nil)
            interval.stringValue = String(format: "%g", value)
            editRevision &+= 1
            saveRuleChanges()
        }
    }
    @objc private func toggleAdvanced() {
        advanced.isHidden.toggle()
        more.title = advanced.isHidden ? "▸ 更多设置" : "▾ 更多设置"
        more.setAccessibilityValue(advanced.isHidden ? "已折叠" : "已展开")
    }
    @objc private func rangeChanged() { chartWindow = [60.0, 300, 600][range.selectedSegment]; render() }
    @objc private func clearHistory() { model.clearHistory() }
    @objc private func testNotification() { model.testNotification() }
    @objc private func rescanSensors() { model.rescan() }
    @objc private func quitMonitor() {
        prepareToClose { [weak self] saved in if saved { self?.model.quitMonitoring() } }
    }
    @objc private func allowNotifications() { model.allowNotifications() }
    @objc private func openNotificationSettings() { model.openNotificationSettings() }
    @objc private func openLoginSettings() { model.openLoginSettings() }
    @objc private func reconnectMonitor() { draftsLoaded = false; model.connect() }

    private func button(_ title: String, action: Selector) -> NSButton {
        let result = NSButton(); configure(result, title: title, action: action); return result
    }
    private func configure(_ button: NSButton, title: String, action: Selector) {
        button.title = title; button.target = self; button.action = action
        button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 13)
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }
}

@MainActor private func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    field.setContentCompressionResistancePriority(.required, for: .horizontal)
    return field
}
@MainActor private func wrappingLabel() -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: "")
    field.font = .systemFont(ofSize: 12)
    return field
}
@MainActor private func numberField(_ name: String, value: String) -> NSTextField {
    let field = NSTextField(string: value)
    field.bezelStyle = .roundedBezel
    field.font = .systemFont(ofSize: 13); field.alignment = .right
    field.setAccessibilityLabel(name)
    field.widthAnchor.constraint(equalToConstant: 72).isActive = true
    return field
}
@MainActor private func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.init(1), for: .horizontal)
    view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    return view
}
@MainActor private func vertical(_ views: [NSView] = [], spacing: CGFloat = 12) -> NSStackView {
    for view in views { view.translatesAutoresizingMaskIntoConstraints = false }
    let stack = NSStackView(views: views)
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
    stack.detachesHiddenViews = true; stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}
@MainActor private func horizontal(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
    for view in views { view.translatesAutoresizingMaskIntoConstraints = false }
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}
@MainActor private func pair(_ first: NSView, _ second: NSView) -> NSStackView {
    let stack = horizontal([first, second], spacing: 24); stack.distribution = .fillEqually; return stack
}
@MainActor private func unit(_ text: String) -> NSTextField {
    let field = label(text); field.textColor = .secondaryLabelColor
    field.widthAnchor.constraint(equalToConstant: 22).isActive = true
    return field
}
@MainActor private func numeric(_ title: String, _ field: NSTextField, _ suffix: String) -> NSStackView {
    horizontal([label(title), spacer(), field, unit(suffix)])
}

private final class FlippedDocumentView: NSView { override var isFlipped: Bool { true } }
private final class RoundedCardView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
    }
}
