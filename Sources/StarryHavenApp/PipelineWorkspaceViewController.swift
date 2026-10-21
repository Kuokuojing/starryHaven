import AppKit
import UniformTypeIdentifiers
import StarryHavenCore

class PipelineWorkspaceViewController: NSViewController {
    let fileList: FileListController
    let optionsStack: NSStackView
    let preview = ImagePreviewView()
    let runButton = NSButton(title: "开始", target: nil, action: nil)
    let progress = NSProgressIndicator()
    let status = NSTextField(labelWithString: "就绪")
    let logView = NSTextView()
    private var framesPanel: NSView!
    private var optionsPanel: NSView!
    private var previewPanel: NSView!
    private var logPanel: NSView!
    private var titleLabel: NSTextField!
    private var running = false

    init(title: String, addTitle: String) {
        self.fileList = FileListController(allowsReference: false, addTitle: addTitle)
        self.optionsStack = NSStackView()
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        titleLabel = UI.label(title ?? "", size: 24, weight: .semibold)

        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 8
        optionsStack.translatesAutoresizingMaskIntoConstraints = false

        framesPanel = UI.group("帧", content: fileList.view)
        optionsPanel = UI.group("设置", content: optionsStack)
        previewPanel = UI.group("预览", content: preview)

        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.textContainerInset = NSSize(width: 5, height: 4)
        let logScroll = NSScrollView()
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.documentView = logView
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        logPanel = UI.group("日志", content: logScroll)

        runButton.bezelStyle = .rounded
        runButton.controlSize = .large
        runButton.target = self
        runButton.action = #selector(start)
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        for v in ([framesPanel, optionsPanel, previewPanel, logPanel, titleLabel, runButton, progress, status] as [NSView]) {
            v.translatesAutoresizingMaskIntoConstraints = true
            root.addSubview(v)
        }
        self.view = root
        buildOptions()
    }

    /// Subclasses add their controls here.
    func buildOptions() {}

    /// Subclasses implement the real pipeline. They are responsible for saving
    /// their own artifact and may return a display-referred preview.
    func execute(lights: [URL], progress: @escaping (Double, String) -> Void) throws -> (image: ImageBuffer, log: [String]) {
        fatalError("execute must be overridden")
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let w = view.bounds.width, h = view.bounds.height
        guard w > 700, h > 400 else { return }
        titleLabel.frame = NSRect(x: 20, y: h - 52, width: 400, height: 32)
        runButton.frame = NSRect(x: w - 140, y: h - 50, width: 120, height: 30)
        let panelBottom: CGFloat = 120
        let panelTop = h - 70
        let framesWidth: CGFloat = 340
        let optionsWidth: CGFloat = 360
        framesPanel.frame = NSRect(x: 18, y: panelBottom, width: framesWidth, height: panelTop - panelBottom)
        optionsPanel.frame = NSRect(x: 18 + framesWidth + 12, y: panelBottom, width: optionsWidth, height: panelTop - panelBottom)
        previewPanel.frame = NSRect(x: 18 + framesWidth + optionsWidth + 24, y: panelBottom,
                                    width: w - (18 + framesWidth + optionsWidth + 24) - 18,
                                    height: panelTop - panelBottom)
        logPanel.frame = NSRect(x: 18, y: 46, width: w - 36, height: 64)
        progress.frame = NSRect(x: 20, y: 16, width: 240, height: 12)
        status.frame = NSRect(x: 272, y: 10, width: w - 292, height: 20)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let dir = ProcessInfo.processInfo.environment["STARRYHAVEN_UI_FRAMES_DIR"] {
            let urls = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir),
                                                                      includingPropertiesForKeys: nil)) ?? [])
                .filter { ["tif", "tiff", "fit", "fits", "png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if !urls.isEmpty { fileList.setURLs(urls) }
        }
        if ProcessInfo.processInfo.environment["STARRYHAVEN_UI_RUN"] != nil, !fileList.urls.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start() }
        }
    }

    @objc func start() {
        guard !running else { return }
        guard !fileList.urls.isEmpty else {
            UI.alert("请先导入帧")
            return
        }
        running = true
        runButton.isEnabled = false
        progress.isHidden = false
        progress.doubleValue = 0
        status.stringValue = "处理中…"
        logView.string = ""
        let lights = fileList.urls
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try self.execute(lights: lights) { p, message in
                    DispatchQueue.main.async {
                        self.progress.doubleValue = p
                        self.status.stringValue = message
                        self.append(message)
                    }
                }
                DispatchQueue.main.async {
                    self.running = false
                    self.runButton.isEnabled = true
                    self.progress.doubleValue = 1
                    self.preview.show(UI.image(from: result.image, displayReferred: true),
                                      caption: "\(result.image.width)×\(result.image.height)")
                    for line in result.log { self.append(line) }
                    self.status.stringValue = "完成"
                }
            } catch {
                DispatchQueue.main.async {
                    self.running = false
                    self.runButton.isEnabled = true
                    self.progress.isHidden = true
                    self.status.stringValue = "失败：\(error)"
                    self.append("错误：\(error)")
                    UI.alert("处理失败", informative: "\(error)")
                }
            }
        }
    }

    func append(_ line: String) {
        logView.string += (logView.string.isEmpty ? "" : "\n") + line
        logView.scrollToEndOfDocument(nil)
    }

    func imageOutputRow(title: String, defaultName: String, action: Selector) -> (row: NSView, field: NSTextField, format: NSPopUpButton) {
        let field = NSTextField(string: NSString(string: "~/Desktop/\(defaultName)").expandingTildeInPath)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let browse = NSButton(title: "浏览…", target: self, action: action)
        let format = UI.popup(OutputFormat.allCases.map { $0.rawValue }, target: nil, action: nil)
        let row = UI.horizontalStack([field, browse], spacing: 6)
        return (row, field, format)
    }
}

final class StarTrailWorkspaceViewController: PipelineWorkspaceViewController {
    private let methodPopup = UI.popup(["最大值（星轨）", "均值", "中值", "最小值"], target: nil, action: nil)
    private let landscapePopup = UI.popup(["固定地景", "动态地景"], target: nil, action: nil)
    private let removeAircraft = NSButton(checkboxWithTitle: "去除飞机/卫星轨迹", target: nil, action: nil)
    private let outputField = NSTextField(string: NSString(string: "~/Desktop/星轨.tif").expandingTildeInPath)
    private let formatPopup = UI.popup(OutputFormat.allCases.map { $0.rawValue }, target: nil, action: nil)
    private let vignetteSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let distortionSlider = NSSlider(value: 0, minValue: -1, maxValue: 1, target: nil, action: nil)
    private let glowSlider = NSSlider(value: 0, minValue: 0, maxValue: 3, target: nil, action: nil)
    private let glowRadiusSlider = NSSlider(value: 2, minValue: 0.5, maxValue: 8, target: nil, action: nil)

    init() { super.init(title: "星轨", addTitle: "导入序列…") }
    required init?(coder: NSCoder) { fatalError() }

    override func buildOptions() {
        outputField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        let browse = NSButton(title: "浏览…", target: self, action: #selector(browse))
        optionsStack.addArrangedSubview(UI.horizontalStack([UI.label("合成", color: .secondaryLabelColor), methodPopup], spacing: 8))
        optionsStack.addArrangedSubview(UI.horizontalStack([UI.label("地景", color: .secondaryLabelColor), landscapePopup], spacing: 8))
        for s in [vignetteSlider, distortionSlider] {
            s.widthAnchor.constraint(equalToConstant: 160).isActive = true
            s.isContinuous = true
        }
        optionsStack.addArrangedSubview(UI.horizontalStack([UI.label("暗角", color: .secondaryLabelColor), vignetteSlider], spacing: 8))
        optionsStack.addArrangedSubview(UI.horizontalStack([UI.label("畸变", color: .secondaryLabelColor), distortionSlider], spacing: 8))
        for s in [glowSlider, glowRadiusSlider] {
            s.widthAnchor.constraint(equalToConstant: 160).isActive = true
            s.isContinuous = true
        }
        optionsStack.addArrangedSubview(UI.horizontalStack([UI.label("辉光", color: .secondaryLabelColor), glowSlider], spacing: 8))
        optionsStack.addArrangedSubview(UI.horizontalStack([UI.label("辉光半径", color: .secondaryLabelColor), glowRadiusSlider], spacing: 8))
        optionsStack.addArrangedSubview(removeAircraft)
        optionsStack.addArrangedSubview(UI.horizontalStack([UI.label("格式", color: .secondaryLabelColor), formatPopup], spacing: 8))
        optionsStack.addArrangedSubview(UI.horizontalStack([outputField, browse], spacing: 6))
    }

    func projectState() -> TrailProjectState {
        var p = TrailProjectState()
        p.frames = fileList.urls.map { $0.path }
        p.method = [StackMethod.maximum, .mean, .median, .minimum][max(0, min(3, methodPopup.indexOfSelectedItem))].rawValue
        p.landscape = landscapePopup.indexOfSelectedItem == 1 ? LandscapeMotion.dynamic.rawValue : LandscapeMotion.fixed.rawValue
        p.removeAircraft = removeAircraft.state == .on
        p.outputPath = outputField.stringValue
        p.outputFormat = OutputFormat.allCases[formatPopup.indexOfSelectedItem].rawValue
        return p
    }

    func apply(project p: TrailProjectState) {
        fileList.setURLs(p.frames.map { URL(fileURLWithPath: $0) })
        let methods: [StackMethod] = [.maximum, .mean, .median, .minimum]
        if let idx = methods.firstIndex(where: { $0.rawValue == p.method }) { methodPopup.selectItem(at: idx) }
        landscapePopup.selectItem(at: p.landscape == LandscapeMotion.dynamic.rawValue ? 1 : 0)
        removeAircraft.state = p.removeAircraft ? .on : .off
        if let path = p.outputPath { outputField.stringValue = path }
        if let idx = OutputFormat.allCases.firstIndex(where: { $0.rawValue == p.outputFormat }) { formatPopup.selectItem(at: idx) }
    }

    @objc private func browse() {
        if let url = UI.saveImage(defaultName: "星轨.tif", format: OutputFormat.allCases[formatPopup.indexOfSelectedItem]) {
            outputField.stringValue = url.path
        }
    }

    override func execute(lights: [URL], progress: @escaping (Double, String) -> Void) throws -> (image: ImageBuffer, log: [String]) {
        var request = StarTrailRequest()
        request.lights = lights
        request.method = [StackMethod.maximum, .mean, .median, .minimum][max(0, min(3, methodPopup.indexOfSelectedItem))]
        request.landscape = landscapePopup.indexOfSelectedItem == 1 ? .dynamic : .fixed
        request.removeAircraft = removeAircraft.state == .on
        request.vignetteCorrection = vignetteSlider.doubleValue
        request.distortionCorrection = distortionSlider.doubleValue
        request.glow = glowSlider.doubleValue
        request.glowRadius = glowRadiusSlider.doubleValue
        request.outputURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STARRYHAVEN_UI_OUTPUT"] ?? outputField.stringValue)
        request.outputFormat = OutputFormat.allCases[formatPopup.indexOfSelectedItem]
        let result = try StarTrailPipeline.run(request, progress: progress)
        return (result.preview, result.log)
    }
}

final class TimelapseWorkspaceViewController: PipelineWorkspaceViewController {
    private let deflickerPopup = UI.popup(["关闭去闪", "默认去闪（15）", "强力去闪（31）"], target: nil, action: nil)
    private let fpsPopup = UI.popup(["12", "24", "30"], target: nil, action: nil)
    private let keyframeCheck = NSButton(checkboxWithTitle: "导出关键帧", target: nil, action: nil)
    private let videoField = NSTextField(string: NSString(string: "~/Desktop/星空延时.mp4").expandingTildeInPath)
    private let keyframeField = NSTextField(string: NSString(string: "~/Desktop/延时关键帧").expandingTildeInPath)

    init() { super.init(title: "星空延时", addTitle: "导入序列…") }
    required init?(coder: NSCoder) { fatalError() }

    override func buildOptions() {
        fpsPopup.selectItem(at: 1)
        deflickerPopup.selectItem(at: 1)
        for f in [videoField, keyframeField] { f.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true }
        let videoBrowse = NSButton(title: "浏览…", target: self, action: #selector(browseVideo))
        let keyBrowse = NSButton(title: "浏览…", target: self, action: #selector(browseKeyframes))
        optionsStack.addArrangedSubview(UI.horizontalStack([UI.label("去闪", color: .secondaryLabelColor), deflickerPopup], spacing: 8))
        optionsStack.addArrangedSubview(UI.horizontalStack([UI.label("帧率", color: .secondaryLabelColor), fpsPopup], spacing: 8))
        optionsStack.addArrangedSubview(UI.horizontalStack([UI.label("视频", color: .secondaryLabelColor), videoField, videoBrowse], spacing: 6))
        optionsStack.addArrangedSubview(keyframeCheck)
        optionsStack.addArrangedSubview(UI.horizontalStack([UI.label("关键帧", color: .secondaryLabelColor), keyframeField, keyBrowse], spacing: 6))
    }

    func projectState() -> TimelapseProjectState {
        var p = TimelapseProjectState()
        p.frames = fileList.urls.map { $0.path }
        p.deflickerWindow = [0, 15, 31][max(0, min(2, deflickerPopup.indexOfSelectedItem))]
        p.fps = Int(fpsPopup.titleOfSelectedItem ?? "24") ?? 24
        p.videoPath = videoField.stringValue
        p.keyframeDirectory = keyframeCheck.state == .on ? keyframeField.stringValue : nil
        return p
    }

    func apply(project p: TimelapseProjectState) {
        fileList.setURLs(p.frames.map { URL(fileURLWithPath: $0) })
        deflickerPopup.selectItem(at: p.deflickerWindow == 31 ? 2 : (p.deflickerWindow == 0 ? 0 : 1))
        fpsPopup.selectItem(withTitle: String(p.fps))
        if let path = p.videoPath { videoField.stringValue = path }
        if let dir = p.keyframeDirectory {
            keyframeCheck.state = .on
            keyframeField.stringValue = dir
        }
    }

    @objc private func browseVideo() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "星空延时.mp4"
        if let t = UTType(filenameExtension: "mp4") { panel.allowedContentTypes = [t] }
        if panel.runModal() == .OK, let url = panel.url { videoField.stringValue = url.path }
    }

    @objc private func browseKeyframes() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { keyframeField.stringValue = url.path }
    }

    override func execute(lights: [URL], progress: @escaping (Double, String) -> Void) throws -> (image: ImageBuffer, log: [String]) {
        var request = TimelapseRequest()
        request.frames = lights
        request.deflickerWindow = [0, 15, 31][max(0, min(2, deflickerPopup.indexOfSelectedItem))]
        request.fps = Int32(fpsPopup.titleOfSelectedItem ?? "24") ?? 24
        request.outputVideoURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STARRYHAVEN_UI_OUTPUT"] ?? videoField.stringValue)
        if keyframeCheck.state == .on {
            request.keyframeDirectory = URL(fileURLWithPath: keyframeField.stringValue)
            request.keyframeEvery = max(1, lights.count / 20)
        }
        let result = try TimelapseProcessor.run(request, progress: progress)
        let preview = result.firstPreview ?? ImageBuffer(width: 32, height: 32, channels: 3)
        return (preview, result.log)
    }
}

final class PanoramaWorkspaceViewController: PipelineWorkspaceViewController {
    private let referenceStepper = NSStepper()
    private let referenceLabel = NSTextField(labelWithString: "1")
    private let outputField = NSTextField(string: NSString(string: "~/Desktop/全景接片.tif").expandingTildeInPath)
    private let formatPopup = UI.popup(OutputFormat.allCases.map { $0.rawValue }, target: nil, action: nil)

    init() { super.init(title: "全景接片", addTitle: "导入帧…") }
    required init?(coder: NSCoder) { fatalError() }

    override func buildOptions() {
        referenceStepper.minValue = 1
        referenceStepper.maxValue = 50
        referenceStepper.increment = 1
        referenceStepper.valueWraps = false
        referenceLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        referenceStepper.target = self
        referenceStepper.action = #selector(referenceChanged)
        outputField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let browse = NSButton(title: "浏览…", target: self, action: #selector(browse))
        optionsStack.addArrangedSubview(UI.horizontalStack([UI.label("参考帧", color: .secondaryLabelColor), referenceLabel, referenceStepper], spacing: 8))
        optionsStack.addArrangedSubview(UI.horizontalStack([UI.label("格式", color: .secondaryLabelColor), formatPopup], spacing: 8))
        optionsStack.addArrangedSubview(UI.horizontalStack([outputField, browse], spacing: 6))
    }

    @objc private func referenceChanged() {
        referenceLabel.stringValue = "\(Int(referenceStepper.doubleValue))"
    }

    func projectState() -> PanoramaProjectState {
        var p = PanoramaProjectState()
        p.frames = fileList.urls.map { $0.path }
        p.referenceIndex = max(0, Int(referenceStepper.doubleValue) - 1)
        p.outputPath = outputField.stringValue
        p.outputFormat = OutputFormat.allCases[formatPopup.indexOfSelectedItem].rawValue
        return p
    }

    func apply(project p: PanoramaProjectState) {
        fileList.setURLs(p.frames.map { URL(fileURLWithPath: $0) })
        referenceStepper.doubleValue = Double(p.referenceIndex + 1)
        referenceLabel.stringValue = "\(p.referenceIndex + 1)"
        if let path = p.outputPath { outputField.stringValue = path }
        if let idx = OutputFormat.allCases.firstIndex(where: { $0.rawValue == p.outputFormat }) { formatPopup.selectItem(at: idx) }
    }

    @objc private func browse() {
        if let url = UI.saveImage(defaultName: "全景接片.tif", format: OutputFormat.allCases[formatPopup.indexOfSelectedItem]) {
            outputField.stringValue = url.path
        }
    }

    override func execute(lights: [URL], progress: @escaping (Double, String) -> Void) throws -> (image: ImageBuffer, log: [String]) {
        var request = PanoramaRequest()
        request.frames = lights
        request.referenceIndex = max(0, Int(referenceStepper.doubleValue) - 1)
        request.outputURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STARRYHAVEN_UI_OUTPUT"] ?? outputField.stringValue)
        request.outputFormat = OutputFormat.allCases[formatPopup.indexOfSelectedItem]
        let result = try PanoramaStitcher.run(request, progress: progress)
        return (result.preview, result.log)
    }
}

final class NarrowbandWorkspaceViewController: NSViewController {
    private let haField = NSTextField(string: "")
    private let oiiiField = NSTextField(string: "")
    private let siiField = NSTextField(string: "")
    private let palettePopup = UI.popup(NarrowbandPalette.allCases.map { $0.rawValue }, target: nil, action: nil)
    private let starlessCheck = NSButton(checkboxWithTitle: "使用 StarNet2 去除星点", target: nil, action: nil)
    private let outputField = NSTextField(string: NSString(string: "~/Desktop/窄带合成.tif").expandingTildeInPath)
    private let formatPopup = UI.popup(OutputFormat.allCases.map { $0.rawValue }, target: nil, action: nil)
    private let preview = ImagePreviewView()
    private let runButton = NSButton(title: "开始合成", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private let status = NSTextField(labelWithString: "就绪")
    private let logView = NSTextView()
    private let optionsStack = NSStackView()
    private var optionsPanel: NSView!
    private var previewPanel: NSView!
    private var logPanel: NSView!
    private var titleLabel: NSTextField!
    private var running = false

    override func loadView() {
        let root = NSView()
        titleLabel = UI.label("窄带", size: 24, weight: .semibold)
        optionsStack.orientation = .vertical
        optionsStack.alignment = .leading
        optionsStack.spacing = 8
        optionsStack.translatesAutoresizingMaskIntoConstraints = false

        func channelRow(_ name: String, field: NSTextField, action: Selector) -> NSView {
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
            let button = NSButton(title: "选择…", target: self, action: action)
            return UI.horizontalStack([UI.label(name, color: .secondaryLabelColor), field, button], spacing: 6)
        }
        optionsStack.addArrangedSubview(channelRow("Ha", field: haField, action: #selector(pickHa)))
        optionsStack.addArrangedSubview(channelRow("OIII", field: oiiiField, action: #selector(pickOIII)))
        optionsStack.addArrangedSubview(channelRow("SII", field: siiField, action: #selector(pickSII)))
        optionsStack.addArrangedSubview(UI.horizontalStack([UI.label("调色", color: .secondaryLabelColor), palettePopup], spacing: 8))
        optionsStack.addArrangedSubview(starlessCheck)
        optionsStack.addArrangedSubview(UI.horizontalStack([UI.label("格式", color: .secondaryLabelColor), formatPopup], spacing: 8))
        outputField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let browse = NSButton(title: "浏览…", target: self, action: #selector(browse))
        optionsStack.addArrangedSubview(UI.horizontalStack([outputField, browse], spacing: 6))

        optionsPanel = UI.group("通道", content: optionsStack)
        previewPanel = UI.group("预览", content: preview)
        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        let logScroll = NSScrollView()
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.documentView = logView
        logView.isVerticallyResizable = true
        logView.autoresizingMask = [.width]
        logView.textContainer?.widthTracksTextView = true
        logPanel = UI.group("日志", content: logScroll)

        runButton.bezelStyle = .rounded
        runButton.controlSize = .large
        runButton.target = self
        runButton.action = #selector(start)
        progress.style = .bar
        progress.isIndeterminate = false
        progress.isHidden = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        for v in ([optionsPanel, previewPanel, logPanel, titleLabel, runButton, progress, status] as [NSView]) {
            v.translatesAutoresizingMaskIntoConstraints = true
            root.addSubview(v)
        }
        self.view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let w = view.bounds.width, h = view.bounds.height
        guard w > 700, h > 400 else { return }
        titleLabel.frame = NSRect(x: 20, y: h - 52, width: 400, height: 32)
        runButton.frame = NSRect(x: w - 150, y: h - 50, width: 130, height: 30)
        optionsPanel.frame = NSRect(x: 18, y: 120, width: 390, height: h - 190)
        previewPanel.frame = NSRect(x: 420, y: 120, width: w - 438, height: h - 190)
        logPanel.frame = NSRect(x: 18, y: 46, width: w - 36, height: 64)
        progress.frame = NSRect(x: 20, y: 16, width: 240, height: 12)
        status.frame = NSRect(x: 272, y: 10, width: w - 292, height: 20)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        let env = ProcessInfo.processInfo.environment
        if let p = env["STARRYHAVEN_UI_HA"] { haField.stringValue = p }
        if let p = env["STARRYHAVEN_UI_OIII"] { oiiiField.stringValue = p }
        if let p = env["STARRYHAVEN_UI_SII"] { siiField.stringValue = p }
        if env["STARRYHAVEN_UI_RUN"] != nil && !haField.stringValue.isEmpty && !oiiiField.stringValue.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.start() }
        }
    }

    func projectState() -> NarrowbandProjectState {
        var p = NarrowbandProjectState()
        p.ha = haField.stringValue.isEmpty ? nil : haField.stringValue
        p.oiii = oiiiField.stringValue.isEmpty ? nil : oiiiField.stringValue
        p.sii = siiField.stringValue.isEmpty ? nil : siiField.stringValue
        p.palette = NarrowbandPalette.allCases[max(0, min(NarrowbandPalette.allCases.count - 1, palettePopup.indexOfSelectedItem))].rawValue
        p.removeStars = starlessCheck.state == .on
        p.outputPath = outputField.stringValue
        return p
    }

    func apply(project p: NarrowbandProjectState) {
        haField.stringValue = p.ha ?? ""
        oiiiField.stringValue = p.oiii ?? ""
        siiField.stringValue = p.sii ?? ""
        if let idx = NarrowbandPalette.allCases.firstIndex(where: { $0.rawValue == p.palette }) { palettePopup.selectItem(at: idx) }
        starlessCheck.state = p.removeStars ? .on : .off
        if let path = p.outputPath { outputField.stringValue = path }
    }

    private func pick(_ field: NSTextField) {
        if let url = UI.openImages(allowsMultiple: false, message: "选择窄带通道").first { field.stringValue = url.path }
    }
    @objc private func pickHa() { pick(haField) }
    @objc private func pickOIII() { pick(oiiiField) }
    @objc private func pickSII() { pick(siiField) }

    @objc private func browse() {
        if let url = UI.saveImage(defaultName: "窄带合成.tif", format: OutputFormat.allCases[formatPopup.indexOfSelectedItem]) {
            outputField.stringValue = url.path
        }
    }

    @objc private func start() {
        guard !running else { return }
        guard !haField.stringValue.isEmpty, !oiiiField.stringValue.isEmpty else {
            UI.alert("请选择 Ha 和 OIII 通道")
            return
        }
        running = true
        runButton.isEnabled = false
        progress.isHidden = false
        progress.doubleValue = 0
        status.stringValue = "处理中…"
        logView.string = ""
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var request = NarrowbandRequest()
                request.ha = URL(fileURLWithPath: self.haField.stringValue)
                request.oiii = URL(fileURLWithPath: self.oiiiField.stringValue)
                request.sii = self.siiField.stringValue.isEmpty ? nil : URL(fileURLWithPath: self.siiField.stringValue)
                request.palette = NarrowbandPalette.allCases[max(0, min(NarrowbandPalette.allCases.count - 1, self.palettePopup.indexOfSelectedItem))]
                request.removeStars = self.starlessCheck.state == .on
                request.outputURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STARRYHAVEN_UI_OUTPUT"] ?? self.outputField.stringValue)
                request.outputFormat = OutputFormat.allCases[self.formatPopup.indexOfSelectedItem]
                let result = try NarrowbandComposer.run(request) { p, m in
                    DispatchQueue.main.async {
                        self.progress.doubleValue = p
                        self.status.stringValue = m
                        self.logView.string += (self.logView.string.isEmpty ? "" : "\n") + m
                    }
                }
                DispatchQueue.main.async {
                    self.running = false
                    self.runButton.isEnabled = true
                    self.progress.doubleValue = 1
                    self.preview.show(UI.image(from: result.preview, displayReferred: true),
                                      caption: "\(result.image.width)×\(result.image.height)")
                    for line in result.log { self.logView.string += (self.logView.string.isEmpty ? "" : "\n") + line }
                    self.status.stringValue = "完成"
                }
            } catch {
                DispatchQueue.main.async {
                    self.running = false
                    self.runButton.isEnabled = true
                    self.progress.isHidden = true
                    self.status.stringValue = "失败：\(error)"
                    UI.alert("合成失败", informative: "\(error)")
                }
            }
        }
    }
}
