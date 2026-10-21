import AppKit
import StarryHavenCore

struct ToolOutput {
    var image: ImageBuffer
    var log: String
    var payload: Any?
}

final class ToolboxWorkspaceViewController: NSViewController {
    private let tabs = NSTabView()

    override func loadView() {
        let root = NSView()
        let title = UI.label("工具箱", size: 24, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        tabs.translatesAutoresizingMaskIntoConstraints = false

        let panels: [NSViewController] = [
            StarSplitPanel(),
            DenoisePanel(),
            SkyLandPanel(),
            WhiteBalancePanel(),
            StarShrinkPanel(),
            EnhancePanel(),
        ]
        for panel in panels {
            addChild(panel)
            let item = NSTabViewItem(identifier: panel.title ?? "")
            item.label = panel.title ?? ""
            let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 660))
            wrapper.autoresizingMask = [.width, .height]
            panel.view.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(panel.view)
            NSLayoutConstraint.activate([
                panel.view.topAnchor.constraint(equalTo: wrapper.topAnchor),
                panel.view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                panel.view.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                panel.view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            ])
            item.view = wrapper
            tabs.addTabViewItem(item)
        }
        root.addSubview(title)
        root.addSubview(tabs)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            tabs.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            tabs.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        self.view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let rect = tabs.contentRect
        for item in tabs.tabViewItems { item.view?.frame = rect }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if let s = ProcessInfo.processInfo.environment["STARRYHAVEN_UI_TAB"], let idx = Int(s), idx >= 0, idx < tabs.numberOfTabViewItems {
            tabs.selectTabViewItem(at: idx)
        }
    }
}

class ToolPanelViewController: NSViewController {
    private let inputField = NSTextField(string: "")
    private let chooseButton = NSButton(title: "选择…", target: nil, action: nil)
    private let preview = ImagePreviewView()
    private let runButton = NSButton(title: "运行", target: nil, action: nil)
    private let saveButton = NSButton(title: "另存为…", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    let status = NSTextField(labelWithString: "选择一张图像开始")
    private let optionsView: NSView?
    private(set) var inputImage: ImageBuffer?
    var outputImage: ImageBuffer?
    var saveName = "结果.tif"

    init(title: String, options: NSView?) {
        self.optionsView = options
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    /// Subclasses implement the real processing call.
    func perform(input: ImageBuffer, progress: @escaping (Double, String) -> Void) throws -> ToolOutput {
        fatalError("perform(input:) must be overridden")
    }

    required init?(coder: NSCoder) { fatalError() }

    private var inputRow: NSView!
    private var previewBox: NSView!
    private var optionsBox: NSView?
    private var footer: NSView!

    override func loadView() {
        let root = NSView()

        inputField.placeholderString = "输入图像路径"
        inputField.font = .systemFont(ofSize: 12)
        inputField.target = self
        inputField.action = #selector(pathEntered)
        chooseButton.target = self
        chooseButton.action = #selector(chooseInput)
        chooseButton.controlSize = .small
        inputRow = UI.horizontalStack([UI.label("输入", color: .secondaryLabelColor), inputField, chooseButton], spacing: 8)

        previewBox = UI.group("预览", content: preview)
        optionsBox = optionsView

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        runButton.target = self
        runButton.action = #selector(run)
        runButton.bezelStyle = .rounded
        runButton.controlSize = .large
        runButton.isEnabled = false
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.isEnabled = false
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .large
        saveButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
        runButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer = UI.horizontalStack([spinner, status, spacer, saveButton, runButton], spacing: 10)

        for v in [inputRow, previewBox, footer].compactMap({ $0 }) {
            v.translatesAutoresizingMaskIntoConstraints = true
            v.autoresizingMask = []
        }
        root.addSubview(inputRow)
        root.addSubview(previewBox)
        if let optionsBox = optionsBox {
            optionsBox.translatesAutoresizingMaskIntoConstraints = true
            root.addSubview(optionsBox)
        }
        root.addSubview(footer)
        self.view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let w = view.bounds.width, h = view.bounds.height
        guard w > 40, h > 80 else { return }
        inputRow.frame = NSRect(x: 12, y: h - 38, width: w - 24, height: 30)
        footer.frame = NSRect(x: 16, y: 8, width: w - 32, height: 30)
        var previewTop = inputRow.frame.minY - 10
        if let options = optionsBox {
            let natural = max(options.fittingSize.height, 30)
            let oh = min(natural, h * 0.42)
            options.frame = NSRect(x: 16, y: previewTop - oh, width: w - 32, height: oh)
            options.layoutSubtreeIfNeeded()
            previewTop = options.frame.minY - 10
        }
        let previewBottom = footer.frame.maxY + 10
        previewBox.frame = NSRect(x: 12, y: previewBottom, width: w - 24, height: max(120, previewTop - previewBottom))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard let path = ProcessInfo.processInfo.environment["STARRYHAVEN_UI_INPUT"], !path.isEmpty else { return }
        if inputField.stringValue.isEmpty {
            inputField.stringValue = path
            runButton.isEnabled = true
        }
        if ProcessInfo.processInfo.environment["STARRYHAVEN_UI_RUN"] != nil, outputImage == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.run() }
        }
    }

    @objc private func chooseInput() {
        let urls = UI.openImages(allowsMultiple: false, message: "选择输入图像")
        guard let url = urls.first else { return }
        inputField.stringValue = url.path
        runButton.isEnabled = true
        status.stringValue = url.lastPathComponent
    }

    @objc private func pathEntered() {
        runButton.isEnabled = !inputField.stringValue.isEmpty
    }

    @objc private func run() {
        guard !inputField.stringValue.isEmpty else { return }
        let url = URL(fileURLWithPath: inputField.stringValue)
        spinner.startAnimation(nil)
        runButton.isEnabled = false
        saveButton.isEnabled = false
        status.stringValue = "处理中…"
        preview.show(nil, caption: "")
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let input = try ImageLoader.loadDisplayReferred(url: url)
                let output = try self.perform(input: input) { p, message in
                    DispatchQueue.main.async {
                        self.status.stringValue = String(format: "%3.0f%% %@", p * 100, message)
                    }
                }
                DispatchQueue.main.async {
                    self.inputImage = input
                    self.outputImage = output.image
                    self.preview.show(UI.image(from: output.image, displayReferred: true),
                                      caption: "\(output.image.width)×\(output.image.height)")
                    self.status.stringValue = output.log
                    self.spinner.stopAnimation(nil)
                    self.runButton.isEnabled = true
                    self.saveButton.isEnabled = true
                    self.didFinish(output)
                }
            } catch {
                DispatchQueue.main.async {
                    self.spinner.stopAnimation(nil)
                    self.runButton.isEnabled = true
                    self.status.stringValue = "失败：\(error)"
                    UI.alert("处理失败", informative: "\(error)")
                }
            }
        }
    }

    func didFinish(_ output: ToolOutput) {}

    func display(_ image: ImageBuffer, name: String, caption: String = "") {
        outputImage = image
        saveName = name
        preview.show(UI.image(from: image, displayReferred: true), caption: caption)
        saveButton.isEnabled = true
    }

    @objc func save() {
        guard let image = outputImage else { return }
        guard let url = UI.saveImage(defaultName: saveName, format: .tiff16) else { return }
        do {
            try ImageWriter.saveDisplay(image, url: url, format: ImageWriter.format(for: url))
            status.stringValue = "已保存 \(url.lastPathComponent)"
        } catch {
            UI.alert("保存失败", informative: "\(error)")
        }
    }
}

func toolSliderRow(_ title: String, minValue: Double, maxValue: Double, value: Double,
                   target: AnyObject?, action: Selector?) -> (row: NSView, slider: NSSlider, value: NSTextField) {
    let slider = NSSlider(value: value, minValue: minValue, maxValue: maxValue, target: target, action: action)
    slider.isContinuous = true
    slider.widthAnchor.constraint(equalToConstant: 240).isActive = true
    let valueLabel = NSTextField(labelWithString: String(format: "%.2f", value))
    valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    valueLabel.textColor = .secondaryLabelColor
    valueLabel.widthAnchor.constraint(equalToConstant: 46).isActive = true
    let label = UI.label(title, color: .secondaryLabelColor)
    label.widthAnchor.constraint(equalToConstant: 76).isActive = true
    let row = UI.horizontalStack([label, slider, valueLabel], spacing: 8)
    return (row, slider, valueLabel)
}

// MARK: - 星点分离｜合成

final class StarSplitPanel: ToolPanelViewController {
    private let modeControl = NSSegmentedControl(labels: ["合成", "去除星点", "星点层"], trackingMode: .selectOne, target: nil, action: nil)
    private let amountRow: (row: NSView, slider: NSSlider, value: NSTextField)
    private var split: StarSeparation.Result?

    init() {
        modeControl.selectedSegment = 0
        amountRow = toolSliderRow("星点强度", minValue: 0, maxValue: 1, value: 1, target: nil, action: nil)
        let options = UI.verticalStack([UI.horizontalStack([UI.label("输出", color: .secondaryLabelColor), modeControl], spacing: 8), amountRow.row], spacing: 8)
        super.init(title: "星点分离｜合成", options: options)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        amountRow.slider.target = self
        amountRow.slider.action = #selector(modeChanged)
        saveName = "星点合成.tif"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func perform(input: ImageBuffer, progress: @escaping (Double, String) -> Void) throws -> ToolOutput {
        let result = try StarSeparation.separate(image: input, stride: 256, progress: { p in progress(p, "StarNet2") })
        let recomposed = StarSeparation.recompose(starless: result.starless, stars: result.stars,
                                                  amount: amountRow.slider.doubleValue)
        return ToolOutput(image: recomposed, log: result.backend, payload: result)
    }

    override func didFinish(_ output: ToolOutput) {
        split = output.payload as? StarSeparation.Result
        updateDisplay()
    }

    @objc private func modeChanged() {
        amountRow.value.stringValue = String(format: "%.2f", amountRow.slider.doubleValue)
        updateDisplay()
    }

    private func updateDisplay() {
        guard let split = split else { return }
        switch modeControl.selectedSegment {
        case 1:
            display(split.starless, name: "去除星点.tif", caption: "starless")
        case 2:
            display(split.stars, name: "星点层.tif", caption: "stars")
        default:
            let rec = StarSeparation.recompose(starless: split.starless, stars: split.stars, amount: amountRow.slider.doubleValue)
            display(rec, name: "星点合成.tif", caption: "recomposed")
        }
    }
}

// MARK: - 降噪

final class DenoisePanel: ToolPanelViewController {
    private let stridePopup = UI.popup(["128", "256", "384"], target: nil, action: nil)

    init() {
        stridePopup.selectItem(at: 1)
        let options = UI.verticalStack([UI.horizontalStack([UI.label("步长", color: .secondaryLabelColor), stridePopup], spacing: 8)], spacing: 8)
        super.init(title: "降噪", options: options)
        saveName = "降噪.tif"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func perform(input: ImageBuffer, progress: @escaping (Double, String) -> Void) throws -> ToolOutput {
        let stride = Int(stridePopup.titleOfSelectedItem ?? "256") ?? 256
        let out = try DeepSNR.denoise(image: input, stride: stride, progress: { p in progress(p, "DeepSNR") })
        return ToolOutput(image: out, log: "DeepSNR · 512 分块 · 步长 \(stride)", payload: nil)
    }
}

// MARK: - 天地分离

final class SkyLandPanel: ToolPanelViewController {
    private let modeControl = NSSegmentedControl(labels: ["SkySeg 自动", "手动黑白蒙版"], trackingMode: .selectOne, target: nil, action: nil)
    private let maskField = NSTextField(string: "")
    private let maskButton = NSButton(title: "选择…", target: nil, action: nil)
    private let applyStretchButton = NSButton(title: "应用天空拉伸", target: nil, action: nil)
    private let applyBalanceButton = NSButton(title: "应用天空背景平衡", target: nil, action: nil)
    private var mask: SkyMask?

    init() {
        modeControl.selectedSegment = 0
        maskField.placeholderString = "黑/白蒙版（白=天空）"
        maskField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let options = UI.verticalStack([
            UI.horizontalStack([UI.label("蒙版", color: .secondaryLabelColor), modeControl], spacing: 8),
            UI.horizontalStack([maskField, maskButton], spacing: 6),
            UI.horizontalStack([applyStretchButton, applyBalanceButton], spacing: 8),
        ], spacing: 8)
        super.init(title: "天地分离", options: options)
        maskButton.target = self
        maskButton.action = #selector(pickMask)
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        applyStretchButton.target = self
        applyStretchButton.action = #selector(applyStretch)
        applyBalanceButton.target = self
        applyBalanceButton.action = #selector(applyBalance)
        saveName = "天空蒙版.tif"
        modeChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func perform(input: ImageBuffer, progress: @escaping (Double, String) -> Void) throws -> ToolOutput {
        let mask: SkyMask
        if modeControl.selectedSegment == 1 {
            let path = maskField.stringValue
            guard !path.isEmpty else {
                throw NSError(domain: "SkyLand", code: 1, userInfo: [NSLocalizedDescriptionKey: "请选择黑白蒙版图像"])
            }
            let m = try ImageLoader.loadDisplayReferred(url: URL(fileURLWithPath: path))
            mask = SkyComposite.manualMask(image: m).upsampled(toWidth: input.width, toHeight: input.height)
        } else {
            progress(0.2, "SkySeg 推理…")
            mask = try SkySegmenter.segment(image: input)
        }
        var maskImage = ImageBuffer(width: mask.width, height: mask.height, channels: 3)
        for i in 0..<mask.mask.count {
            for c in 0..<3 { maskImage.pixels[i * 3 + c] = mask.mask[i] }
        }
        return ToolOutput(image: maskImage, log: "SkySeg ONNX · 320×320 · 白=天空", payload: mask)
    }

    override func didFinish(_ output: ToolOutput) {
        mask = output.payload as? SkyMask
        saveName = "天空蒙版.tif"
    }

    @objc private func modeChanged() {
        let manual = modeControl.selectedSegment == 1
        maskField.isEnabled = manual
        maskButton.isEnabled = manual
    }

    @objc private func pickMask() {
        let urls = UI.openImages(allowsMultiple: false, message: "选择黑/白蒙版")
        if let url = urls.first { maskField.stringValue = url.path }
    }

    @objc private func applyStretch() {
        guard let input = inputImage, let mask = mask else {
            UI.alert("请先计算蒙版")
            return
        }
        let stretched = PostProcess.stretch(input)
        let result = SkyComposite.skyOnly(original: input, effect: stretched, mask: mask)
        display(result, name: "天空拉伸.tif", caption: "sky-only stretch")
        status.stringValue = "已应用：仅天空区域拉伸，地景保持不变"
    }

    @objc private func applyBalance() {
        guard let input = inputImage, let mask = mask else {
            UI.alert("请先计算蒙版")
            return
        }
        let balanced = PostProcess.backgroundBalance(input, grid: 8, degree: 2)
        let result = SkyComposite.skyOnly(original: input, effect: balanced, mask: mask)
        display(result, name: "天空背景平衡.tif", caption: "sky-only background balance")
        status.stringValue = "已应用：仅天空区域背景平衡，地景保持不变"
    }
}

// MARK: - 白平衡校正

final class WhiteBalancePanel: ToolPanelViewController {
    private let modePopup = UI.popup(["自动白平衡", "色温", "不校正"], target: nil, action: nil)
    private let temperatureRow: (row: NSView, slider: NSSlider, value: NSTextField)
    private let tintRow: (row: NSView, slider: NSSlider, value: NSTextField)

    init() {
        temperatureRow = toolSliderRow("色温", minValue: 1000, maxValue: 20000, value: 4700, target: nil, action: nil)
        tintRow = toolSliderRow("色调", minValue: -100, maxValue: 100, value: 0, target: nil, action: nil)
        let options = UI.verticalStack([
            UI.horizontalStack([UI.label("模式", color: .secondaryLabelColor), modePopup], spacing: 8),
            temperatureRow.row,
            tintRow.row,
        ], spacing: 8)
        super.init(title: "白平衡校正", options: options)
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        saveName = "白平衡.tif"
        modeChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func modeChanged() {
        let mode = modePopup.indexOfSelectedItem
        temperatureRow.slider.isEnabled = mode == 1
        tintRow.slider.isEnabled = mode == 1
    }

    override func perform(input: ImageBuffer, progress: @escaping (Double, String) -> Void) throws -> ToolOutput {
        var o = WhiteBalanceOptions()
        switch modePopup.indexOfSelectedItem {
        case 0: o.mode = .auto
        case 1: o.mode = .temperature; o.temperature = temperatureRow.slider.doubleValue; o.tint = tintRow.slider.doubleValue
        default: o.mode = .none
        }
        let out = PostProcess.whiteBalance(input, options: o)
        return ToolOutput(image: out, log: "白平衡：\(o.mode.rawValue)", payload: nil)
    }

    override func didFinish(_ output: ToolOutput) {}
}

// MARK: - 缩星｜星柔

final class EnhancePanel: ToolPanelViewController {
    private let contrastRow: (row: NSView, slider: NSSlider, value: NSTextField)
    private let structureRow: (row: NSView, slider: NSSlider, value: NSTextField)
    private let radiusRow: (row: NSView, slider: NSSlider, value: NSTextField)
    private let skylightRow: (row: NSView, slider: NSSlider, value: NSTextField)
    private let glowRow: (row: NSView, slider: NSSlider, value: NSTextField)
    private let glowRadiusRow: (row: NSView, slider: NSSlider, value: NSTextField)
    private let skyOnlyCheck = NSButton(checkboxWithTitle: "仅作用于天空（SkySeg）", target: nil, action: nil)

    init() {
        contrastRow = toolSliderRow("局部对比", minValue: 0, maxValue: 1, value: 0.35, target: nil, action: nil)
        structureRow = toolSliderRow("结构", minValue: 0, maxValue: 1, value: 0.25, target: nil, action: nil)
        radiusRow = toolSliderRow("结构半径", minValue: 3, maxValue: 120, value: 30, target: nil, action: nil)
        skylightRow = toolSliderRow("天光", minValue: 0, maxValue: 1, value: 0, target: nil, action: nil)
        glowRow = toolSliderRow("星轨辉光", minValue: 0, maxValue: 3, value: 0, target: nil, action: nil)
        glowRadiusRow = toolSliderRow("辉光半径", minValue: 0.5, maxValue: 8, value: 2, target: nil, action: nil)
        let options = UI.verticalStack([
            contrastRow.row, structureRow.row, radiusRow.row,
            skylightRow.row, glowRow.row, glowRadiusRow.row, skyOnlyCheck,
        ], spacing: 6)
        super.init(title: "图像增强", options: options)
        for row in [contrastRow, structureRow, radiusRow, skylightRow, glowRow, glowRadiusRow] {
            row.slider.target = self
            row.slider.action = #selector(valuesChanged)
        }
        saveName = "图像增强.tif"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func perform(input: ImageBuffer, progress: @escaping (Double, String) -> Void) throws -> ToolOutput {
        var options = EnhancementOptions()
        options.localContrast = contrastRow.slider.doubleValue
        options.structure = structureRow.slider.doubleValue
        options.structureRadius = radiusRow.slider.doubleValue
        options.skylight = skylightRow.slider.doubleValue
        options.glow = glowRow.slider.doubleValue
        options.glowRadius = glowRadiusRow.slider.doubleValue
        var mask: SkyMask?
        if skyOnlyCheck.state == .on {
            progress(0.2, "SkySeg 天空蒙版…")
            mask = try SkySegmenter.segment(image: input)
        }
        let out = PostProcess.enhance(input, options: options, mask: mask)
        return ToolOutput(image: out, log: "图像增强：局部对比 \(Int(options.localContrast * 100))% · 结构 \(Int(options.structure * 100))% · 天光 \(Int(options.skylight * 100))%", payload: nil)
    }

    @objc private func valuesChanged() {
        contrastRow.value.stringValue = String(format: "%.2f", contrastRow.slider.doubleValue)
        structureRow.value.stringValue = String(format: "%.2f", structureRow.slider.doubleValue)
        radiusRow.value.stringValue = String(format: "%.0f", radiusRow.slider.doubleValue)
        skylightRow.value.stringValue = String(format: "%.2f", skylightRow.slider.doubleValue)
        glowRow.value.stringValue = String(format: "%.2f", glowRow.slider.doubleValue)
        glowRadiusRow.value.stringValue = String(format: "%.1f", glowRadiusRow.slider.doubleValue)
    }
}

final class StarShrinkPanel: ToolPanelViewController {
    private let amountRow: (row: NSView, slider: NSSlider, value: NSTextField)
    private let softenRow: (row: NSView, slider: NSSlider, value: NSTextField)
    private let radiusRow: (row: NSView, slider: NSSlider, value: NSTextField)

    init() {
        amountRow = toolSliderRow("缩星", minValue: 0, maxValue: 1, value: 0.6, target: nil, action: nil)
        softenRow = toolSliderRow("星柔", minValue: 0, maxValue: 1, value: 0.0, target: nil, action: nil)
        radiusRow = toolSliderRow("半径", minValue: 0.5, maxValue: 3.0, value: 1.0, target: nil, action: nil)
        let options = UI.verticalStack([amountRow.row, softenRow.row, radiusRow.row], spacing: 8)
        super.init(title: "缩星｜星柔", options: options)
        for row in [amountRow, softenRow, radiusRow] {
            row.slider.target = self
            row.slider.action = #selector(valuesChanged)
        }
        saveName = "缩星.tif"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func perform(input: ImageBuffer, progress: @escaping (Double, String) -> Void) throws -> ToolOutput {
        let out = PostProcess.starReduction(input,
                                            amount: amountRow.slider.doubleValue,
                                            softening: softenRow.slider.doubleValue,
                                            radiusScale: radiusRow.slider.doubleValue)
        return ToolOutput(image: out, log: String(format: "缩星 %.0f%% · 星柔 %.0f%%", amountRow.slider.doubleValue * 100, softenRow.slider.doubleValue * 100), payload: nil)
    }

    @objc private func valuesChanged() {
        amountRow.value.stringValue = String(format: "%.2f", amountRow.slider.doubleValue)
        softenRow.value.stringValue = String(format: "%.2f", softenRow.slider.doubleValue)
        radiusRow.value.stringValue = String(format: "%.1f", radiusRow.slider.doubleValue)
    }
}
