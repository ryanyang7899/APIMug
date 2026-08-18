import AppKit

/// 设置窗口：全部代码构建，无 xib。
final class SettingsWindowController: NSObject {
    private let window: NSWindow
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let stack = NSStackView()
    /// 底部固定按钮栏（不随内容滚动）
    private let bottomBar = NSView()
    private let bottomButtonRow = NSStackView()

    private var intervalField: NSTextField!
    private var defaultThresholdField: NSTextField!
    private var balanceCheck: NSButton!
    private var todayUsageCheck: NSButton!
    private var monthUsageCheck: NSButton!
    private var updateFreqPopup: NSPopUpButton!
    private let updateStatusLabel = NSTextField(labelWithString: "")

    private struct SiteRowControls {
        let name: NSTextField
        let enabled: NSButton
        let url: NSTextField
        let token: NSSecureTextField
        let provider: NSPopUpButton
        let threshold: NSTextField
    }
    private var rowControls: [SiteRowControls] = []

    private var config: AppConfig
    var onSave: ((AppConfig) -> Void)?
    var onCheckUpdate: (() -> Void)?

    init(config: AppConfig) {
        self.config = config
        self.window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                               styleMask: [.titled, .closable, .resizable],
                               backing: .buffered, defer: false)
        super.init()
        window.title = "API Mug 设置"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 320)
        setupScroll()
        rebuild()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// 重新以最新配置构建窗口内容
    func updateConfig(_ newConfig: AppConfig) {
        config = newConfig
        rebuild()
    }

    // MARK: - 布局

    private func setupScroll() {
        guard let content = window.contentView else { return }

        // —— 滚动内容区 ——
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView
        content.addSubview(scrollView)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        // —— 底部固定按钮栏 ——
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bottomBar)

        let topBorder = NSBox()
        topBorder.boxType = .separator
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(topBorder)

        bottomButtonRow.orientation = .horizontal
        bottomButtonRow.spacing = 8
        bottomButtonRow.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(bottomButtonRow)

        let applyButton = NSButton(title: "应用", target: self, action: #selector(apply))
        applyButton.bezelStyle = .rounded
        let saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        bottomButtonRow.addArrangedSubview(applyButton)
        bottomButtonRow.addArrangedSubview(saveButton)
        bottomButtonRow.addArrangedSubview(cancelButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            // 底部栏固定在窗口底部
            bottomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 56),

            topBorder.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),

            bottomButtonRow.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            bottomButtonRow.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -16),
        ])
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rowControls = []

        // —— 通用设置 ——
        stack.addArrangedSubview(makeSectionLabel("通用设置"))
        let (intervalLabel, intervalField) = makeLabeledField(label: "自动刷新间隔（分钟）", width: 80)
        intervalField.stringValue = "\(config.refreshIntervalMinutes)"
        self.intervalField = intervalField
        stack.addArrangedSubview(row(with: [intervalLabel, intervalField]))

        let (thresholdLabel, defaultThresholdField) = makeLabeledField(label: "默认低余额阈值", width: 80)
        defaultThresholdField.stringValue = String(format: "%.2f", config.defaultLowBalanceThreshold)
        self.defaultThresholdField = defaultThresholdField
        stack.addArrangedSubview(row(with: [thresholdLabel, defaultThresholdField]))

        let balanceCheck = NSButton(checkboxWithTitle: "菜单栏显示余额总额", target: nil, action: nil)
        balanceCheck.state = (config.showBalanceInMenuBar ?? true) ? .on : .off
        self.balanceCheck = balanceCheck
        stack.addArrangedSubview(balanceCheck)

        let todayUsageCheck = NSButton(checkboxWithTitle: "菜单栏显示本日用量", target: nil, action: nil)
        todayUsageCheck.state = (config.showTodayUsageInMenuBar ?? false) ? .on : .off
        self.todayUsageCheck = todayUsageCheck
        stack.addArrangedSubview(todayUsageCheck)

        let monthUsageCheck = NSButton(checkboxWithTitle: "菜单栏显示本月用量", target: nil, action: nil)
        monthUsageCheck.state = (config.showMonthUsageInMenuBar ?? false) ? .on : .off
        self.monthUsageCheck = monthUsageCheck
        stack.addArrangedSubview(monthUsageCheck)
        stack.addArrangedSubview(makeSeparator())

        // —— 站点 ——
        stack.addArrangedSubview(makeSectionLabel("监测站点"))
        for (i, site) in config.sites.enumerated() {
            stack.addArrangedSubview(makeSiteSection(index: i, site: site))
        }

        let addButton = NSButton(title: "+ 添加站点", target: self, action: #selector(addSite))
        addButton.bezelStyle = .rounded
        stack.addArrangedSubview(addButton)
        stack.addArrangedSubview(makeSeparator())

        // —— 更新 ——
        stack.addArrangedSubview(makeSectionLabel("更新"))

        let freqLabel = makeLabel(width: 110)
        freqLabel.stringValue = "检查更新频率"
        let freqPopup = NSPopUpButton()
        freqPopup.addItems(withTitles: ["关闭", "每次启动", "每天", "每周"])
        switch config.updateCheckFrequency ?? .launch {
        case .never: freqPopup.selectItem(at: 0)
        case .launch: freqPopup.selectItem(at: 1)
        case .daily: freqPopup.selectItem(at: 2)
        case .weekly: freqPopup.selectItem(at: 3)
        }
        self.updateFreqPopup = freqPopup
        stack.addArrangedSubview(row(with: [freqLabel, freqPopup]))

        let checkButton = NSButton(title: "立即检查更新", target: self, action: #selector(checkUpdate))
        checkButton.bezelStyle = .rounded
        stack.addArrangedSubview(checkButton)

        updateStatusLabel.stringValue = ""
        updateStatusLabel.textColor = .secondaryLabelColor
        updateStatusLabel.font = NSFont.systemFont(ofSize: 11)
        updateStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(updateStatusLabel)
        // 底部按钮已固定在窗口底部栏，不在此处
    }

    private func makeSiteSection(index: Int, site: Site) -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6

        section.addArrangedSubview(makeSectionLabel("站点 \(index + 1)"))

        // 名称 + 启用
        let (nameLabel, nameField) = makeLabeledField(label: "名称", width: 200)
        nameField.stringValue = site.name
        let enabledCheck = NSButton(checkboxWithTitle: "启用", target: nil, action: nil)
        enabledCheck.state = site.enabled ? .on : .off
        section.addArrangedSubview(row(with: [nameLabel, nameField, enabledCheck]))

        // URL
        let (urlLabel, urlField) = makeLabeledField(label: "URL", width: 340)
        urlField.stringValue = site.baseURL
        section.addArrangedSubview(row(with: [urlLabel, urlField]))

        // Token（密文输入）
        let tokenLabel = makeLabel()
        tokenLabel.stringValue = "Token"
        let tokenField = NSSecureTextField()
        tokenField.translatesAutoresizingMaskIntoConstraints = false
        tokenField.widthAnchor.constraint(equalToConstant: 340).isActive = true
        tokenField.stringValue = site.apiToken
        section.addArrangedSubview(row(with: [tokenLabel, tokenField]))

        // 协议类型 + 低余额阈值
        let providerLabel = makeLabel()
        providerLabel.stringValue = "类型"
        let providerPopup = NSPopUpButton()
        providerPopup.addItems(withTitles: ["DeepSeek 官方", "OpenAI / NewAPI"])
        providerPopup.selectItem(at: site.provider == .deepseek ? 0 : 1)
        let thresholdLabel = makeLabel()
        thresholdLabel.stringValue = "低余额阈值"
        let thresholdField = NSTextField()
        thresholdField.translatesAutoresizingMaskIntoConstraints = false
        thresholdField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        thresholdField.stringValue = site.lowBalanceThreshold > 0 ? String(format: "%.2f", site.lowBalanceThreshold) : ""
        section.addArrangedSubview(row(with: [providerLabel, providerPopup, thresholdLabel, thresholdField]))

        // 删除
        let removeButton = NSButton(title: "删除此站点", target: self, action: #selector(removeSite))
        removeButton.bezelStyle = .rounded
        removeButton.tag = index
        section.addArrangedSubview(removeButton)

        rowControls.append(SiteRowControls(name: nameField, enabled: enabledCheck,
                                           url: urlField, token: tokenField,
                                           provider: providerPopup, threshold: thresholdField))
        return section
    }

    // MARK: - 小工具

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.boldSystemFont(ofSize: 13)
        return label
    }

    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        return box
    }

    private func makeLabel(width: CGFloat = 80) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    /// 返回 (label, field)，field 宽度固定
    private func makeLabeledField(label: String, width: CGFloat) -> (NSTextField, NSTextField) {
        let l = makeLabel()
        l.stringValue = label
        let f = NSTextField()
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: width).isActive = true
        return (l, f)
    }

    private func row(with views: [NSView]) -> NSStackView {
        let r = NSStackView()
        r.orientation = .horizontal
        r.spacing = 8
        for v in views { r.addArrangedSubview(v) }
        return r
    }

    // MARK: - 数据收集

    /// 把界面字段写回 config（在保存/增删前调用，避免丢编辑）
    private func collectFields() {
        config.refreshIntervalMinutes = max(1, Int(intervalField.stringValue) ?? 30)
        config.defaultLowBalanceThreshold = Double(defaultThresholdField.stringValue) ?? config.defaultLowBalanceThreshold
        config.showBalanceInMenuBar = balanceCheck.state == .on
        config.showTodayUsageInMenuBar = todayUsageCheck.state == .on
        config.showMonthUsageInMenuBar = monthUsageCheck.state == .on
        switch updateFreqPopup.indexOfSelectedItem {
        case 0: config.updateCheckFrequency = .never
        case 2: config.updateCheckFrequency = .daily
        case 3: config.updateCheckFrequency = .weekly
        default: config.updateCheckFrequency = .launch
        }
        for (i, c) in rowControls.enumerated() where i < config.sites.count {
            config.sites[i].name = c.name.stringValue.trimmingCharacters(in: .whitespaces)
            config.sites[i].enabled = c.enabled.state == .on
            config.sites[i].baseURL = c.url.stringValue.trimmingCharacters(in: .whitespaces)
            config.sites[i].apiToken = c.token.stringValue.trimmingCharacters(in: .whitespaces)
            config.sites[i].provider = c.provider.indexOfSelectedItem == 0 ? .deepseek : .newapi
            config.sites[i].lowBalanceThreshold = Double(c.threshold.stringValue) ?? 0
        }
    }

    // MARK: - 动作

    @objc private func addSite() {
        collectFields()
        config.sites.append(Site(id: UUID(), name: "新站点\(config.sites.count + 1)", enabled: true,
                                baseURL: "https://api.deepseek.com", apiToken: "",
                                provider: .deepseek, lowBalanceThreshold: 0))
        rebuild()
    }

    @objc private func removeSite(_ sender: Any?) {
        collectFields()
        guard let btn = sender as? NSButton, btn.tag >= 0, btn.tag < config.sites.count else { return }
        config.sites.remove(at: btn.tag)
        rebuild()
    }

    /// 应用：立即保存设置，不关闭窗口
    @objc private func apply() {
        collectFields()
        onSave?(config)
    }

    /// 立即检查更新（触发后结果由 showUpdateStatus 反馈）
    @objc private func checkUpdate() {
        onCheckUpdate?()
    }

    /// 更新检查结果反馈到设置窗口
    func showUpdateStatus(_ text: String) {
        updateStatusLabel.stringValue = text
    }

    /// 保存：保存设置并关闭窗口
    @objc private func save() {
        collectFields()
        onSave?(config)
        window.close()
    }

    @objc private func cancel() {
        window.close()
    }
}
