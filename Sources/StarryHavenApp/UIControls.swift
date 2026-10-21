import AppKit
import UniformTypeIdentifiers
import StarryHavenCore

enum UI {
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func button(_ title: String, target: AnyObject?, action: Selector?, bezel: NSButton.BezelStyle = .rounded) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = bezel
        b.controlSize = .regular
        return b
    }

    static func checkbox(_ title: String, target: AnyObject?, action: Selector?, state: Bool = false) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: target, action: action)
        b.state = state ? .on : .off
        return b
    }

    static func popup(_ items: [String], target: AnyObject?, action: Selector?) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: items)
        p.target = target
        p.action = action
        return p
    }

    static func group(_ title: String, content: NSView) -> NSView {
        PanelView(title: title, content: content)
    }

    static func verticalStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func horizontalStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func formRow(_ title: String, _ control: NSView, width: CGFloat = 190) -> NSStackView {
        let l = label(title, color: .secondaryLabelColor)
        l.alignment = .right
        l.widthAnchor.constraint(equalToConstant: 92).isActive = true
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
        return horizontalStack([l, control], spacing: 8)
    }

    static func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    static func openImages(allowsMultiple: Bool, message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = allowsMultiple
        panel.message = message
        var types: [UTType] = [.image, .rawImage]
        for ext in ["fits", "fit", "fts"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    static func saveImage(defaultName: String, format: OutputFormat?) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName
        if let format = format {
            if let t = UTType(filenameExtension: format.fileExtension) {
                panel.allowedContentTypes = [t]
            }
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func alert(_ message: String, informative: String = "") {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = informative
        a.alertStyle = .warning
        a.runModal()
    }

    static func image(from buffer: ImageBuffer, displayReferred: Bool) -> NSImage? {
        guard let cg = ImageWriter.cgImage(from: buffer, bits: 8, applyGamma: !displayReferred) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

final class PanelView: NSView {
    init(title: String, content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        let titleLabel = UI.label(title, size: 11, weight: .semibold, color: .secondaryLabelColor)
        let stack = NSStackView(views: [titleLabel, content])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            content.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class ImagePreviewView: NSView {
    private let imageView = NSImageView()
    private let placeholder = NSTextField(labelWithString: "预览")
    private let caption = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        layer?.cornerRadius = 6
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageFrameStyle = .none
        imageView.translatesAutoresizingMaskIntoConstraints = false
        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 13)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        caption.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        caption.textColor = .secondaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        addSubview(placeholder)
        addSubview(caption)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -22),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ image: NSImage?, caption text: String = "") {
        imageView.image = image
        placeholder.isHidden = image != nil
        caption.stringValue = text
    }
}

final class FileListController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let tableView = NSTableView()
    private let scroll = NSScrollView()
    private let addButton: NSButton
    private let removeButton: NSButton
    private let clearButton: NSButton
    private let countLabel = NSTextField(labelWithString: "0 个文件")
    private(set) var urls: [URL] = []
    var referenceIndex: Int = 0
    let allowsReference: Bool
    var onChange: (() -> Void)?

    init(allowsReference: Bool, addTitle: String = "添加…") {
        self.allowsReference = allowsReference
        addButton = NSButton(title: addTitle, target: nil, action: nil)
        removeButton = NSButton(title: "移除", target: nil, action: nil)
        clearButton = NSButton(title: "清空", target: nil, action: nil)
        super.init()
        build()
    }

    var view: NSView { container }

    private let container = NSView()

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        if allowsReference {
            let c0 = NSTableColumn(identifier: .init("ref"))
            c0.title = "参考"
            c0.width = 40
            c0.minWidth = 40
            tableView.addTableColumn(c0)
        }
        let c1 = NSTableColumn(identifier: .init("file"))
        c1.title = "文件"
        c1.width = 260
        tableView.addTableColumn(c1)
        scroll.documentView = tableView

        addButton.target = self; addButton.action = #selector(add)
        removeButton.target = self; removeButton.action = #selector(remove)
        clearButton.target = self; clearButton.action = #selector(clear)
        for b in [addButton, removeButton, clearButton] { b.controlSize = .small }
        addButton.keyEquivalent = ""
        let buttons = UI.horizontalStack([addButton, removeButton, clearButton], spacing: 6)
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        let bottom = UI.horizontalStack([countLabel], spacing: 0)

        container.addSubview(scroll)
        container.addSubview(buttons)
        container.addSubview(bottom)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -6),
            buttons.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            buttons.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -4),
            bottom.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottom.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    @objc private func add() {
        let picked = UI.openImages(allowsMultiple: true, message: "选择帧")
        guard !picked.isEmpty else { return }
        urls.append(contentsOf: picked)
        if referenceIndex >= urls.count { referenceIndex = 0 }
        tableView.reloadData()
        updateCount()
        onChange?()
    }

    @objc private func remove() {
        let rows = tableView.selectedRowIndexes.sorted(by: >)
        guard !rows.isEmpty else { return }
        for r in rows where r < urls.count { urls.remove(at: r) }
        if referenceIndex >= urls.count { referenceIndex = 0 }
        tableView.reloadData()
        updateCount()
        onChange?()
    }

    @objc private func clear() {
        urls.removeAll()
        referenceIndex = 0
        tableView.reloadData()
        updateCount()
        onChange?()
    }

    @objc private func pickReference(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < urls.count else { return }
        referenceIndex = sender.tag
        tableView.reloadData()
        onChange?()
    }

    private func updateCount() {
        countLabel.stringValue = "\(urls.count) 个文件"
    }

    func setURLs(_ newURLs: [URL], reference: Int = 0) {
        urls = newURLs
        referenceIndex = min(max(reference, 0), max(newURLs.count - 1, 0))
        tableView.reloadData()
        updateCount()
        onChange?()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { urls.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < urls.count else { return nil }
        let url = urls[row]
        if tableColumn?.identifier.rawValue == "ref" {
            let cell = NSTableCellView()
            let radio = NSButton(radioButtonWithTitle: "", target: self, action: #selector(pickReference(_:)))
            radio.tag = row
            radio.state = row == referenceIndex ? .on : .off
            radio.frame = NSRect(x: 10, y: 3, width: 18, height: 18)
            cell.addSubview(radio)
            return cell
        }
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: url.lastPathComponent)
        text.font = .systemFont(ofSize: 12)
        text.lineBreakMode = .byTruncatingMiddle
        text.frame = NSRect(x: 4, y: 3, width: max(60, tableView.bounds.width - 50), height: 18)
        text.autoresizingMask = [.width]
        text.toolTip = url.path
        cell.addSubview(text)
        return cell
    }
}
