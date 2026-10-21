import AppKit
import StarryHavenCore
import UniformTypeIdentifiers

final class MainViewController: NSViewController {
    private let sidebarController = SidebarViewController()
    private let detailContainer = NSView()
    private var current: NSViewController?

    override func loadView() {
        let root = NSView()
        addChild(sidebarController)
        sidebarController.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarController.view)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(separator)

        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(detailContainer)

        NSLayoutConstraint.activate([
            sidebarController.view.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarController.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarController.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarController.view.widthAnchor.constraint(equalToConstant: 178),
            separator.leadingAnchor.constraint(equalTo: sidebarController.view.trailingAnchor),
            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            detailContainer.topAnchor.constraint(equalTo: root.topAnchor),
            detailContainer.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.view = root

        sidebarController.onSelect = { [weak self] section in
            self?.show(section)
        }
        let argSections: [(String, SidebarSection)] = [
            ("--stack", .stack), ("--toolbox", .toolbox), ("--trails", .trails),
            ("--timelapse", .timelapse), ("--panorama", .panorama),
            ("--narrowband", .narrowband), ("--home", .home), ("--help", .help),
        ]
        if let match = argSections.first(where: { CommandLine.arguments.contains($0.0) }) {
            sidebarController.select(match.1)
            show(match.1)
        } else {
            show(.home)
        }
        if let path = ProcessInfo.processInfo.environment["STARRYHAVEN_UI_PROJECT_OPEN"] {
            do {
                let project = try StarryHavenProject.load(from: URL(fileURLWithPath: path))
                let vc = show(.stack) as? StackWorkspaceViewController
                if let state = project.stack { vc?.apply(project: state) }
            } catch {
                FileHandle.standardError.write("project open failed: \(error)\n".data(using: .utf8)!)
            }
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        current?.view.frame = detailContainer.bounds
    }

    @discardableResult
    private func show(_ section: SidebarSection) -> NSViewController {
        let controller: NSViewController
        switch section {
        case .home:
            controller = HomeViewController()
        case .help:
            controller = HelpViewController()
        case .stack:
            controller = StackWorkspaceViewController()
        case .trails:
            controller = StarTrailWorkspaceViewController()
        case .timelapse:
            controller = TimelapseWorkspaceViewController()
        case .panorama:
            controller = PanoramaWorkspaceViewController()
        case .narrowband:
            controller = NarrowbandWorkspaceViewController()
        case .toolbox:
            controller = ToolboxWorkspaceViewController()
        }
        current?.view.removeFromSuperview()
        current?.removeFromParent()
        addChild(controller)
        detailContainer.layoutSubtreeIfNeeded()
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.view.frame = detailContainer.bounds
        controller.view.autoresizingMask = [.width, .height]
        detailContainer.addSubview(controller.view)
        current = controller
        return controller
    }

    @objc func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "打开 Starry Haven 项目"
        var types: [UTType] = []
        for ext in ["starproject", "json"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let project = try StarryHavenProject.load(from: url)
            let section: SidebarSection
            switch project.workspace {
            case "trails": section = .trails
            case "panorama": section = .panorama
            case "timelapse": section = .timelapse
            case "narrowband": section = .narrowband
            default: section = .stack
            }
            sidebarController.select(section)
            switch project.workspace {
            case "trails":
                let vc = show(.trails) as? StarTrailWorkspaceViewController
                if let state = project.trails { vc?.apply(project: state) }
            case "panorama":
                let vc = show(.panorama) as? PanoramaWorkspaceViewController
                if let state = project.panorama { vc?.apply(project: state) }
            case "timelapse":
                let vc = show(.timelapse) as? TimelapseWorkspaceViewController
                if let state = project.timelapse { vc?.apply(project: state) }
            case "narrowband":
                let vc = show(.narrowband) as? NarrowbandWorkspaceViewController
                if let state = project.narrowband { vc?.apply(project: state) }
            default:
                let vc = show(.stack) as? StackWorkspaceViewController
                if let state = project.stack { vc?.apply(project: state) }
            }
            view.window?.title = "星空难民营 — \(url.deletingPathExtension().lastPathComponent)"
        } catch {
            UI.alert("打开项目失败", informative: "\(error)")
        }
    }

    @objc func saveProject() {
        var project = StarryHavenProject()
        if let stack = current as? StackWorkspaceViewController {
            project.workspace = "stack"; project.stack = stack.projectState()
        } else if let trails = current as? StarTrailWorkspaceViewController {
            project.workspace = "trails"; project.trails = trails.projectState()
        } else if let panorama = current as? PanoramaWorkspaceViewController {
            project.workspace = "panorama"; project.panorama = panorama.projectState()
        } else if let timelapse = current as? TimelapseWorkspaceViewController {
            project.workspace = "timelapse"; project.timelapse = timelapse.projectState()
        } else if let narrowband = current as? NarrowbandWorkspaceViewController {
            project.workspace = "narrowband"; project.narrowband = narrowband.projectState()
        } else {
            UI.alert("当前工作区不支持保存项目")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Starry Haven 项目.starproject"
        if let t = UTType(filenameExtension: "starproject") { panel.allowedContentTypes = [t] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try project.save(to: url)
            view.window?.title = "星空难民营 — \(url.deletingPathExtension().lastPathComponent)"
        } catch {
            UI.alert("保存项目失败", informative: "\(error)")
        }
    }
}

enum SidebarSection: Int, CaseIterable {
    case home = 0
    case stack = 1
    case trails = 2
    case timelapse = 3
    case panorama = 4
    case narrowband = 5
    case toolbox = 6
    case help = 7

    var title: String {
        switch self {
        case .home: return "首页"
        case .stack: return "星空堆栈"
        case .trails: return "星轨"
        case .timelapse: return "星空延时"
        case .panorama: return "全景接片"
        case .narrowband: return "窄带"
        case .toolbox: return "工具箱"
        case .help: return "帮助"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "house"
        case .stack: return "sparkles"
        case .trails: return "moon.stars"
        case .timelapse: return "film"
        case .panorama: return "rectangle.split.3x1"
        case .narrowband: return "camera.filters"
        case .toolbox: return "square.grid.2x2"
        case .help: return "questionmark.circle"
        }
    }
}

final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onSelect: ((SidebarSection) -> Void)?
    private let tableView = NSTableView()

    override func loadView() {
        let root = NSView()
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        tableView.headerView = nil
        tableView.rowHeight = 30
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.width = 170
        tableView.addTableColumn(column)
        scroll.documentView = tableView
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -40),
        ])
        let footer = NSTextField(labelWithString: "原生 macOS · 线性浮点处理")
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor
        root.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
        ])
        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    func select(_ section: SidebarSection) {
        tableView.selectRowIndexes(IndexSet(integer: section.rawValue), byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { SidebarSection.allCases.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let section = SidebarSection(rawValue: row) ?? .stack
        let cell = NSTableCellView()
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)
        image.contentTintColor = .controlAccentColor
        image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: section.title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: row == 0 ? .medium : .regular)
        cell.addSubview(image)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 18),
            image.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.selectedRow >= 0, let section = SidebarSection(rawValue: tableView.selectedRow) else { return }
        onSelect?(section)
    }
}
