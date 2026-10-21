import AppKit
import UniformTypeIdentifiers
import StarryHavenCore

final class StackWorkspaceViewController: NSViewController {
    private let modeControl = NSSegmentedControl(labels: ["普通模式", "专业模式", "深空"], trackingMode: .selectOne, target: nil, action: nil)
    private let lightList = FileListController(allowsReference: true, addTitle: "导入亮场…")
    private let biasList = FileListController(allowsReference: false, addTitle: "导入偏置…")
    private let darkList = FileListController(allowsReference: false, addTitle: "导入暗场…")
    private let flatList = FileListController(allowsReference: false, addTitle: "导入平场…")

    private let methodPopup = UI.popup(["Sigma 裁剪（推荐）", "均值", "中值", "最大值", "最小值"], target: nil, action: nil)
    private let sigmaPresetPopup = UI.popup([
        "强力去飞机卫星轨迹（2σ / 3σ）",
        "常规去异常（4σ / 5σ，推荐）",
        "保留流星和闪光（6σ / 6σ）",
    ], target: nil, action: nil)
    private let lowSigmaField = NSTextField(string: "4.0")
    private let highSigmaField = NSTextField(string: "5.0")
    private let lowSigmaStepper = NSStepper()
    private let highSigmaStepper = NSStepper()
    private let scenePopup = UI.popup(["全图堆栈", "天地分离堆栈"], target: nil, action: nil)
    private let manualMaskCheckbox = NSButton(checkboxWithTitle: "使用手动天空蒙版", target: nil, action: nil)
    private let manualMaskField = NSTextField(string: "")
    private let manualMaskButton = NSButton(title: "选择…", target: nil, action: nil)
    private let cropCheckbox = NSButton(checkboxWithTitle: "裁切到帧重叠区域", target: nil, action: nil)
    private let backgroundCheckbox = NSButton(checkboxWithTitle: "背景归一化", target: nil, action: nil)
    private let badPixelCheckbox = NSButton(checkboxWithTitle: "坏点校正（需暗场+平场）", target: nil, action: nil)
    private let useBiasCheckbox = NSButton(checkboxWithTitle: "应用偏置场", target: nil, action: nil)
    private let useDarkCheckbox = NSButton(checkboxWithTitle: "应用暗场", target: nil, action: nil)
    private let useFlatCheckbox = NSButton(checkboxWithTitle: "应用平场", target: nil, action: nil)
    private let lensModePopup = UI.popup(["不校正（仅手动）", "自动匹配（EXIF / lensfun）", "加载 Adobe LCP…"], target: nil, action: nil)
    private var lensProfileURL: URL?
    private let vignetteSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let distortionSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let vignetteValue = NSTextField(labelWithString: "0.00")
    private let distortionValue = NSTextField(labelWithString: "0.00")
    private let formatPopup = UI.popup(OutputFormat.allCases.map { $0.rawValue }, target: nil, action: nil)
    private let outputField = NSTextField(string: NSString(string: "~/Desktop/堆栈.tif").expandingTildeInPath)
    private let outputButton = NSButton(title: "浏览…", target: nil, action: nil)
    private let startButton = NSButton(title: "开始堆栈", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "就绪")
    private let preview = ImagePreviewView()
    private let logView = NSTextView()
    private let tabs = NSTabView()
    private var running = false
    private var topBar: NSStackView!
    private var leftContainer: NSView!
    private var settingsBox: NSView!
    private var previewBox: NSView!
    private var logBox: NSView!
    private var footer: NSView!

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = true

        let title = UI.label("星空堆栈", size: 24, weight: .semibold)
        modeControl.selectedSegment = 0
        lensModePopup.selectItem(at: 1)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.segmentStyle = .rounded
        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startStack)
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerSpacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 10).isActive = true
        topBar = UI.horizontalStack([title, modeControl, headerSpacer, startButton], spacing: 18)
        topBar.distribution = .fill
        topBar.heightAnchor.constraint(equalToConstant: 46).isActive = true

        buildTabs()
        let framesBox = UI.group("帧", content: tabs)
        framesBox.translatesAutoresizingMaskIntoConstraints = false

        let settings = buildSettings()
        settingsBox = UI.group("堆栈设置", content: settings)
        settingsBox.translatesAutoresizingMaskIntoConstraints = false

        previewBox = UI.group("预览", content: preview)
        previewBox.translatesAutoresizingMaskIntoConstraints = false

        logView.isEditable = false
        logView.isSelectable = true
        logView.drawsBackground = true
        logView.backgroundColor = .textBackgroundColor
        logView.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        logView.textColor = .labelColor
        logView.textContainerInset = NSSize(width: 6, height: 5)
        let logScroll = NSScrollView()
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.documentView = logView
        logView.minSize = NSSize(width: 0, height: 0)
        logView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = false
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        logBox = UI.group("日志", content: logScroll)
        logBox.translatesAutoresizingMaskIntoConstraints = false

        previewBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        previewBox.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        previewBox.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewBox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        logBox.heightAnchor.constraint(equalToConstant: 150).isActive = true

        leftContainer = NSView()
        leftContainer.translatesAutoresizingMaskIntoConstraints = false
        leftContainer.addSubview(framesBox)
        NSLayoutConstraint.activate([
            framesBox.topAnchor.constraint(equalTo: leftContainer.topAnchor),
            framesBox.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor),
            framesBox.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor),
            framesBox.bottomAnchor.constraint(equalTo: leftContainer.bottomAnchor),
        ])
        settingsBox.widthAnchor.constraint(equalToConstant: 370).isActive = true
        leftContainer.widthAnchor.constraint(equalToConstant: 410).isActive = true

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.isHidden = true
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(progress)
        footer.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            progress.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 2),
            progress.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 230),
            statusLabel.leadingAnchor.constraint(equalTo: progress.trailingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            footer.heightAnchor.constraint(equalToConstant: 26),
        ])

        root.addSubview(topBar)
        root.addSubview(leftContainer)
        root.addSubview(settingsBox)
        root.addSubview(previewBox)
        root.addSubview(logBox)
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            topBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            topBar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            leftContainer.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 14),
            leftContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            leftContainer.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            settingsBox.topAnchor.constraint(equalTo: leftContainer.topAnchor),
            settingsBox.leadingAnchor.constraint(equalTo: leftContainer.trailingAnchor, constant: 14),
            settingsBox.bottomAnchor.constraint(lessThanOrEqualTo: leftContainer.bottomAnchor),
            previewBox.topAnchor.constraint(equalTo: leftContainer.topAnchor),
            previewBox.leadingAnchor.constraint(equalTo: settingsBox.trailingAnchor, constant: 14),
            previewBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            logBox.topAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: 10),
            logBox.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
            logBox.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
            logBox.bottomAnchor.constraint(equalTo: leftContainer.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
        self.view = root

        wire()
        applyPreset()
        updateTabLabels()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let rect = tabs.contentRect
        for item in tabs.tabViewItems { item.view?.frame = rect }
    }

    private func buildTabs() {
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        tabs.heightAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        let lists: [(String, FileListController)] = [
            ("亮场", lightList), ("偏置场", biasList), ("暗场", darkList), ("平场", flatList),
        ]
        for (title, list) in lists {
            let item = NSTabViewItem(identifier: title)
            item.label = title
            let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 520))
            wrapper.autoresizingMask = [.width, .height]
            list.view.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(list.view)
            NSLayoutConstraint.activate([
                list.view.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 8),
                list.view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 8),
                list.view.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -8),
                list.view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -8),
            ])
            item.view = wrapper
            tabs.addTabViewItem(item)
        }
    }

    private func buildSettings() -> NSView {
        for f in [lowSigmaField, highSigmaField] {
            f.alignment = .right
            f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            f.widthAnchor.constraint(equalToConstant: 52).isActive = true
        }
        for s in [lowSigmaStepper, highSigmaStepper] {
            s.minValue = 0.5
            s.maxValue = 12
            s.increment = 0.5
            s.valueWraps = false
        }
        lowSigmaStepper.doubleValue = 4
        highSigmaStepper.doubleValue = 5
        let lowRow = UI.horizontalStack([UI.label("低 σ", color: .secondaryLabelColor), lowSigmaField, lowSigmaStepper], spacing: 6)
        let highRow = UI.horizontalStack([UI.label("高 σ", color: .secondaryLabelColor), highSigmaField, highSigmaStepper], spacing: 6)

        manualMaskField.isEditable = false
        manualMaskField.placeholderString = "选择黑白蒙版图像"
        manualMaskField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
        let maskRow = UI.horizontalStack([manualMaskCheckbox, manualMaskField, manualMaskButton], spacing: 6)

        outputField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let outputRow = UI.horizontalStack([outputField, outputButton], spacing: 6)

        let calibration = UI.verticalStack([
            useBiasCheckbox, useDarkCheckbox, useFlatCheckbox, badPixelCheckbox,
        ], spacing: 4)
        sigmaPresetPopup.selectItem(at: 1)
        sigmaPresetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        let stackOptions = UI.verticalStack([
            UI.horizontalStack([UI.label("方法", color: .secondaryLabelColor), methodPopup], spacing: 8),
            UI.horizontalStack([UI.label("Sigma 预设", color: .secondaryLabelColor), sigmaPresetPopup], spacing: 8),
            lowRow, highRow,
            UI.horizontalStack([UI.label("场景", color: .secondaryLabelColor), scenePopup], spacing: 8),
            maskRow,
            cropCheckbox, backgroundCheckbox,
        ], spacing: 7)
        let output = UI.verticalStack([
            UI.horizontalStack([UI.label("格式", color: .secondaryLabelColor), formatPopup], spacing: 8),
            outputRow,
        ], spacing: 7)

        for (slider, value) in [(vignetteSlider, vignetteValue), (distortionSlider, distortionValue)] {
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
            value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            value.textColor = .secondaryLabelColor
            value.widthAnchor.constraint(equalToConstant: 44).isActive = true
        }
        lensModePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        let lens = UI.verticalStack([
            UI.horizontalStack([UI.label("配置", color: .secondaryLabelColor), lensModePopup], spacing: 8),
            UI.horizontalStack([UI.label("暗角", color: .secondaryLabelColor), vignetteSlider, vignetteValue], spacing: 8),
            UI.horizontalStack([UI.label("畸变", color: .secondaryLabelColor), distortionSlider, distortionValue], spacing: 8),
        ], spacing: 7)

        let settings = UI.verticalStack([
            UI.group("校准", content: calibration),
            UI.group("镜头校正", content: lens),
            UI.group("堆栈", content: stackOptions),
            UI.group("输出", content: output),
        ], spacing: 10)
        for panel in settings.arrangedSubviews {
            panel.widthAnchor.constraint(equalTo: settings.widthAnchor).isActive = true
        }
        return settings
    }

    private func wire() {
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        methodPopup.target = self
        methodPopup.action = #selector(methodChanged)
        sigmaPresetPopup.target = self
        sigmaPresetPopup.action = #selector(sigmaPresetChanged)
        scenePopup.target = self
        scenePopup.action = #selector(sceneChanged)
        manualMaskCheckbox.target = self
        manualMaskCheckbox.action = #selector(sceneChanged)
        manualMaskButton.target = self
        manualMaskButton.action = #selector(pickManualMask)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        outputButton.target = self
        outputButton.action = #selector(browseOutput)
        startButton.target = self
        startButton.action = #selector(startStack)
        lowSigmaStepper.target = self
        lowSigmaStepper.action = #selector(sigmaStepperChanged)
        highSigmaStepper.target = self
        highSigmaStepper.action = #selector(sigmaStepperChanged)
        lowSigmaField.target = self
        lowSigmaField.action = #selector(sigmaFieldChanged)
        lensModePopup.target = self
        lensModePopup.action = #selector(lensModeChanged)
        vignetteSlider.target = self
        vignetteSlider.action = #selector(lensChanged)
        distortionSlider.target = self
        distortionSlider.action = #selector(lensChanged)
        highSigmaField.target = self
        highSigmaField.action = #selector(sigmaFieldChanged)
        for list in [lightList, biasList, darkList, flatList] {
            list.onChange = { [weak self] in
                self?.updateTabLabels()
                self?.updateCalibrationAvailability()
            }
        }
        updateCalibrationAvailability()
        methodChanged()
        sceneChanged()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let dir = ProcessInfo.processInfo.environment["STARRYHAVEN_UI_STACK_DIR"] else { return }
        let fm = FileManager.default
        let urls = ((try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? [])
            .filter { ["tif", "tiff", "fit", "fits", "png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !urls.isEmpty else { return }
        lightList.setURLs(urls, reference: 0)
        updateTabLabels()
        if let out = ProcessInfo.processInfo.environment["STARRYHAVEN_UI_STACK_OUT"] {
            outputField.stringValue = out
        }
        if let path = ProcessInfo.processInfo.environment["STARRYHAVEN_UI_PROJECT_SAVE"] {
            var project = StarryHavenProject()
            project.workspace = "stack"
            project.stack = projectState()
            try? project.save(to: URL(fileURLWithPath: path))
        }
        if ProcessInfo.processInfo.environment["STARRYHAVEN_UI_STACK_RUN"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startStack() }
        }
    }

    private func updateTabLabels() {
        let counts = [lightList.urls.count, biasList.urls.count, darkList.urls.count, flatList.urls.count]
        let names = ["亮场", "偏置场", "暗场", "平场"]
        for i in 0..<4 {
            tabs.tabViewItem(at: i).label = "\(names[i]) (\(counts[i]))"
        }
    }

    private func updateCalibrationAvailability() {
        useBiasCheckbox.isEnabled = !biasList.urls.isEmpty
        useDarkCheckbox.isEnabled = !darkList.urls.isEmpty
        useFlatCheckbox.isEnabled = !flatList.urls.isEmpty
        badPixelCheckbox.isEnabled = !darkList.urls.isEmpty && !flatList.urls.isEmpty
        if useBiasCheckbox.isEnabled && !useBiasCheckbox.state.isOn {
            useBiasCheckbox.state = .on
        }
        if useDarkCheckbox.isEnabled && !useDarkCheckbox.state.isOn {
            useDarkCheckbox.state = .on
        }
        if useFlatCheckbox.isEnabled && !useFlatCheckbox.state.isOn {
            useFlatCheckbox.state = .on
        }
    }


    // MARK: - Project documents

    func projectState() -> StackProjectState {
        var p = StackProjectState()
        p.lights = lightList.urls.map { $0.path }
        p.bias = biasList.urls.map { $0.path }
        p.dark = darkList.urls.map { $0.path }
        p.flat = flatList.urls.map { $0.path }
        p.referenceIndex = lightList.referenceIndex
        p.mode = [StackMode.normal, .professional, .deepSky][max(0, min(2, modeControl.selectedSegment))].rawValue
        p.method = [StackMethod.sigmaClipped, .mean, .median, .maximum, .minimum][max(0, min(4, methodPopup.indexOfSelectedItem))].rawValue
        p.lowSigma = lowSigmaField.doubleValue
        p.highSigma = highSigmaField.doubleValue
        p.sceneMode = scenePopup.indexOfSelectedItem == 1 ? SceneMode.skyLand.rawValue : SceneMode.fullFrame.rawValue
        p.manualMask = manualMaskField.stringValue.isEmpty ? nil : manualMaskField.stringValue
        p.cropToOverlap = cropCheckbox.state == .on
        p.badPixelCorrection = badPixelCheckbox.state == .on
        p.normalizeBackground = backgroundCheckbox.state == .on
        p.vignetteCorrection = vignetteSlider.doubleValue
        p.distortionCorrection = distortionSlider.doubleValue
        switch lensModePopup.indexOfSelectedItem {
        case 1: p.lensMode = "automatic"
        case 2: p.lensMode = "lcp"; p.lcpPath = lensProfileURL?.path
        default: p.lensMode = "none"
        }
        p.outputPath = outputField.stringValue
        p.outputFormat = OutputFormat.allCases[max(0, min(OutputFormat.allCases.count - 1, formatPopup.indexOfSelectedItem))].rawValue
        return p
    }

    func apply(project p: StackProjectState) {
        lightList.setURLs(p.lights.map { URL(fileURLWithPath: $0) }, reference: p.referenceIndex)
        biasList.setURLs(p.bias.map { URL(fileURLWithPath: $0) })
        darkList.setURLs(p.dark.map { URL(fileURLWithPath: $0) })
        flatList.setURLs(p.flat.map { URL(fileURLWithPath: $0) })
        if let idx = [StackMode.normal, .professional, .deepSky].firstIndex(where: { $0.rawValue == p.mode }) {
            modeControl.selectedSegment = idx
        }
        let methods: [StackMethod] = [.sigmaClipped, .mean, .median, .maximum, .minimum]
        if let idx = methods.firstIndex(where: { $0.rawValue == p.method }) { methodPopup.selectItem(at: idx) }
        lowSigmaField.stringValue = String(format: "%.1f", p.lowSigma)
        highSigmaField.stringValue = String(format: "%.1f", p.highSigma)
        lowSigmaStepper.doubleValue = p.lowSigma
        highSigmaStepper.doubleValue = p.highSigma
        if abs(p.lowSigma - 2) < 0.01 && abs(p.highSigma - 3) < 0.01 { sigmaPresetPopup.selectItem(at: 0) }
        else if abs(p.lowSigma - 6) < 0.01 && abs(p.highSigma - 6) < 0.01 { sigmaPresetPopup.selectItem(at: 2) }
        else { sigmaPresetPopup.selectItem(at: 1) }
        scenePopup.selectItem(at: p.sceneMode == SceneMode.skyLand.rawValue ? 1 : 0)
        manualMaskField.stringValue = p.manualMask ?? ""
        manualMaskCheckbox.state = p.manualMask == nil ? .off : .on
        cropCheckbox.state = p.cropToOverlap ? .on : .off
        badPixelCheckbox.state = p.badPixelCorrection ? .on : .off
        backgroundCheckbox.state = p.normalizeBackground ? .on : .off
        vignetteSlider.doubleValue = p.vignetteCorrection
        distortionSlider.doubleValue = p.distortionCorrection
        vignetteValue.stringValue = String(format: "%.2f", p.vignetteCorrection)
        distortionValue.stringValue = String(format: "%.2f", p.distortionCorrection)
        switch p.lensMode {
        case "automatic": lensModePopup.selectItem(at: 1); lensProfileURL = nil
        case "lcp":
            lensModePopup.selectItem(at: 2)
            lensProfileURL = p.lcpPath.map { URL(fileURLWithPath: $0) }
        default: lensModePopup.selectItem(at: 0); lensProfileURL = nil
        }
        if let path = p.outputPath { outputField.stringValue = path }
        if let idx = OutputFormat.allCases.firstIndex(where: { $0.rawValue == p.outputFormat }) {
            formatPopup.selectItem(at: idx)
        }
        updateTabLabels()
        updateCalibrationAvailability()
        methodChanged()
        sceneChanged()
    }

    @objc private func modeChanged() {
        applyPreset()
    }

    private func applyPreset() {
        switch modeControl.selectedSegment {
        case 1:
            cropCheckbox.state = .on
            badPixelCheckbox.state = .on
            backgroundCheckbox.state = .on
            scenePopup.selectItem(at: 0)
            lensModePopup.selectItem(at: 1)
            lensProfileURL = nil
        case 2:
            cropCheckbox.state = .on
            badPixelCheckbox.state = .on
            backgroundCheckbox.state = .on
            scenePopup.selectItem(at: 0)
            lensModePopup.selectItem(at: 0)
            lensProfileURL = nil
        default:
            cropCheckbox.state = .off
            badPixelCheckbox.state = .off
            backgroundCheckbox.state = .on
            scenePopup.selectItem(at: 0)
            lensModePopup.selectItem(at: 1)
            lensProfileURL = nil
        }
        methodPopup.selectItem(at: 0)
        sigmaPresetPopup.selectItem(at: 1)
        lowSigmaField.stringValue = "4.0"
        highSigmaField.stringValue = "5.0"
        lowSigmaStepper.doubleValue = 4
        highSigmaStepper.doubleValue = 5
        methodChanged()
        sceneChanged()
    }

    @objc private func sigmaPresetChanged() {
        let presets: [(Double, Double)] = [(2, 3), (4, 5), (6, 6)]
        let index = max(0, min(2, sigmaPresetPopup.indexOfSelectedItem))
        lowSigmaField.stringValue = String(format: "%.1f", presets[index].0)
        highSigmaField.stringValue = String(format: "%.1f", presets[index].1)
        lowSigmaStepper.doubleValue = presets[index].0
        highSigmaStepper.doubleValue = presets[index].1
    }

    @objc private func methodChanged() {
        let sigma = methodPopup.indexOfSelectedItem == 0
        lowSigmaField.isEnabled = sigma
        highSigmaField.isEnabled = sigma
        lowSigmaStepper.isEnabled = sigma
        highSigmaStepper.isEnabled = sigma
    }

    @objc private func sceneChanged() {
        let skyLand = scenePopup.indexOfSelectedItem == 1
        manualMaskCheckbox.isEnabled = skyLand
        let useManual = skyLand && manualMaskCheckbox.state == .on
        manualMaskField.isEnabled = useManual
        manualMaskButton.isEnabled = useManual
    }

    @objc private func pickManualMask() {
        let urls = UI.openImages(allowsMultiple: false, message: "选择黑/白天空蒙版")
        if let url = urls.first { manualMaskField.stringValue = url.path }
    }

    @objc private func formatChanged() {
        let format = OutputFormat.allCases[formatPopup.indexOfSelectedItem]
        let current = outputField.stringValue
        if current.isEmpty { return }
        let ns = current as NSString
        outputField.stringValue = ns.deletingPathExtension + "." + format.fileExtension
    }

    @objc private func lensModeChanged() {
        if lensModePopup.indexOfSelectedItem == 2 {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.allowsMultipleSelection = false
            panel.message = "选择 Adobe LCP 镜头配置文件"
            if let t = UTType(filenameExtension: "lcp") { panel.allowedContentTypes = [t] }
            panel.allowsOtherFileTypes = true
            if panel.runModal() == .OK, let url = panel.url {
                lensProfileURL = url
            } else {
                lensModePopup.selectItem(at: 0)
                lensProfileURL = nil
            }
        } else {
            lensProfileURL = nil
        }
    }

    @objc private func lensChanged() {
        vignetteValue.stringValue = String(format: "%.2f", vignetteSlider.doubleValue)
        distortionValue.stringValue = String(format: "%.2f", distortionSlider.doubleValue)
    }

    @objc private func browseOutput() {
        let format = OutputFormat.allCases[formatPopup.indexOfSelectedItem]
        if let url = UI.saveImage(defaultName: (outputField.stringValue as NSString).lastPathComponent, format: format) {
            outputField.stringValue = url.path
            formatPopup.selectItem(at: OutputFormat.allCases.firstIndex(of: ImageWriter.format(for: url)) ?? 0)
        }
    }

    @objc private func sigmaStepperChanged() {
        lowSigmaField.stringValue = String(format: "%.1f", lowSigmaStepper.doubleValue)
        highSigmaField.stringValue = String(format: "%.1f", highSigmaStepper.doubleValue)
    }

    @objc private func sigmaFieldChanged() {
        lowSigmaStepper.doubleValue = min(max(lowSigmaField.doubleValue, 0.5), 12)
        highSigmaStepper.doubleValue = min(max(highSigmaField.doubleValue, 0.5), 12)
        sigmaStepperChanged()
    }

    private func appendLog(_ line: String) {
        logView.string += (logView.string.isEmpty ? "" : "\n") + line
        logView.scrollToEndOfDocument(nil)
    }

    @objc private func startStack() {
        guard !running else { return }
        guard !lightList.urls.isEmpty else {
            UI.alert("请先导入亮场", informative: "至少需要一帧亮场图像。")
            return
        }
        guard !outputField.stringValue.isEmpty else {
            UI.alert("请选择输出位置")
            return
        }
        let outputURL = URL(fileURLWithPath: outputField.stringValue)
        var request = StackRequest()
        request.lights = lightList.urls
        request.biasFrames = biasList.urls
        request.darkFrames = darkList.urls
        request.flatFrames = flatList.urls
        request.referenceIndex = lightList.referenceIndex
        request.mode = [StackMode.normal, .professional, .deepSky][max(0, min(2, modeControl.selectedSegment))]
        request.method = [StackMethod.sigmaClipped, .mean, .median, .maximum, .minimum][max(0, min(4, methodPopup.indexOfSelectedItem))]
        request.lowSigma = lowSigmaField.doubleValue
        request.highSigma = highSigmaField.doubleValue
        request.sceneMode = scenePopup.indexOfSelectedItem == 1 ? .skyLand : .fullFrame
        request.manualMaskURL = manualMaskCheckbox.state == .on && !manualMaskField.stringValue.isEmpty
            ? URL(fileURLWithPath: manualMaskField.stringValue) : nil
        request.cropToOverlap = cropCheckbox.state == .on
        request.badPixelCorrection = badPixelCheckbox.state == .on
        request.normalizeBackground = backgroundCheckbox.state == .on
        request.vignetteCorrection = vignetteSlider.doubleValue
        request.distortionCorrection = distortionSlider.doubleValue
        switch lensModePopup.indexOfSelectedItem {
        case 1: request.lensProfileMode = .automatic
        case 2:
            if let url = lensProfileURL { request.lensProfileMode = .adobeLCP(url) }
        default: request.lensProfileMode = .none
        }
        request.outputURL = outputURL
        request.outputFormat = OutputFormat.allCases[formatPopup.indexOfSelectedItem]
        let useBias = useBiasCheckbox.state == .on
        let useDark = useDarkCheckbox.state == .on
        let useFlat = useFlatCheckbox.state == .on
        if !useBias { request.biasFrames = [] }
        if !useDark { request.darkFrames = [] }
        if !useFlat { request.flatFrames = [] }

        running = true
        startButton.isEnabled = false
        progress.isHidden = false
        progress.doubleValue = 0
        statusLabel.stringValue = "准备…"
        logView.string = ""
        let started = Date()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try StackPipeline.run(request) { p, message in
                    DispatchQueue.main.async {
                        self.progress.doubleValue = p
                        self.statusLabel.stringValue = message
                        self.appendLog(String(format: "[%3.0f%%] %@", p * 100, message))
                    }
                }
                DispatchQueue.main.async {
                    self.running = false
                    self.startButton.isEnabled = true
                    self.progress.doubleValue = 1
                    let elapsed = Date().timeIntervalSince(started)
                    self.statusLabel.stringValue = String(format: "完成 · %d 帧 · %.1f×%.1f · %.1fs", result.usedFrames, Double(result.image.width), Double(result.image.height), elapsed)
                    self.preview.show(UI.image(from: result.preview, displayReferred: true),
                                      caption: "\(result.image.width)×\(result.image.height) · \(result.usedFrames) 帧")
                    for line in result.log where !self.logView.string.contains(line) {
                        self.appendLog(line)
                    }
                    if let url = result.outputURL {
                        self.appendLog("输出：\(url.path)")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.running = false
                    self.startButton.isEnabled = true
                    self.progress.isHidden = true
                    self.statusLabel.stringValue = "失败：\(error)"
                    self.appendLog("错误：\(error)")
                    UI.alert("堆栈失败", informative: "\(error)")
                }
            }
        }
    }
}

private extension NSButton.StateValue {
    var isOn: Bool { self == .on }
}
