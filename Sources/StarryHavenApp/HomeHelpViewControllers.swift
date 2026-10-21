import AppKit

enum AppAssets {
    static func image(_ name: String) -> NSImage? {
        if let resource = Bundle.main.resourceURL {
            let url = resource.appendingPathComponent(name)
            if let image = NSImage(contentsOf: url) { return image }
        }
        let desktop = NSString(string: "~/Desktop/\(name)").expandingTildeInPath
        return NSImage(contentsOfFile: desktop)
    }

    static func attachment(_ name: String, width: CGFloat) -> NSAttributedString? {
        guard let image = image(name), image.size.width > 0 else { return nil }
        let height = width * image.size.height / image.size.width
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: 0, width: width, height: height)
        return NSAttributedString(attachment: attachment)
    }
}

private func articleStyle() -> NSMutableParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = 7
    style.paragraphSpacing = 12
    style.alignment = .left
    return style
}

private func articleText(_ text: String, size: CGFloat = 14.5, weight: NSFont.Weight = .regular,
                         color: NSColor = .labelColor, style: NSParagraphStyle? = nil) -> NSAttributedString {
    NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style ?? articleStyle(),
    ])
}

final class ArticleTextView: NSView {
    let textView = NSTextView()
    private let scroll = NSScrollView()
    private var maxTextWidth: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 42, height: 30)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        scroll.documentView = textView
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setContent(_ content: NSAttributedString) {
        textView.textStorage?.setAttributedString(content)
        layoutTextView()
        DispatchQueue.main.async { [weak self] in self?.scrollToTop() }
    }

    private func scrollToTop() {
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func setBackgroundColor(_ color: NSColor) {
        scroll.drawsBackground = true
        scroll.backgroundColor = color
        textView.drawsBackground = true
        textView.backgroundColor = color
    }

    func setMaxTextWidth(_ width: CGFloat) {
        maxTextWidth = width
        layoutTextView()
    }

    override func layout() {
        super.layout()
        layoutTextView()
    }

    private func layoutTextView() {
        let width = scroll.contentSize.width
        guard width > 10 else { return }
        textView.frame = NSRect(x: 0, y: 0, width: width, height: max(scroll.contentSize.height, 10))
        if let container = textView.textContainer, let layout = textView.layoutManager {
            let available = width - textView.textContainerInset.width * 2
            let textWidth = min(maxTextWidth ?? available, available)
            container.containerSize = NSSize(width: max(textWidth, 10),
                                             height: CGFloat.greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            textView.frame = NSRect(x: 0, y: 0, width: width,
                                    height: max(used.height + textView.textContainerInset.height * 2 + 20, scroll.contentSize.height))
        }
    }
}

final class HomeViewController: NSViewController {
    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.white.cgColor
        let article = ArticleTextView()
        article.setBackgroundColor(.white)
        article.setMaxTextWidth(700)
        article.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(article)
        NSLayoutConstraint.activate([
            article.topAnchor.constraint(equalTo: root.topAnchor),
            article.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            article.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            article.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        self.view = root

        let content = NSMutableAttributedString()
        if let logo = AppAssets.attachment("logo-b-rounded.png", width: 220) {
            content.append(logo)
            content.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 8)]))
        }
        content.append(articleText("星空难民营，门虚掩，灯常亮，帐篷不大，夜色管够。\n", size: 25, weight: .semibold,
                                   style: {
                                       let s = articleStyle(); s.lineSpacing = 7.5; s.paragraphSpacing = 17.5; return s
                                   }()))
        let bodyStyle = articleStyle()
        bodyStyle.lineSpacing = 5.2
        bodyStyle.paragraphSpacing = 17.5
        content.append(articleText("""
        此处不设前台不问来路，只问星点对齐否。
        市面星空软件，菜单套娃，会员催租，界面像从上世纪课件里出土。我索性攒了一个：能堆栈、能校准、能对齐星点、能去星、能降噪；星轨、延时、全景、窄带，也略通拳脚。参数有点认人，按钮有点慢热，模型挑图如挑食。但路子是按拍星人的夜路踩出来的：多出图，少绕弯，少熬夜。
        你若也拍星空，拿去用便是。遇问题或想聊拍摄、后期、代码，欢迎加群。邮箱：kuojing@qq.com。加群与反馈皆可发信，标题写“星空难民营”即可。一人守营，回复不保证秒回，保证不是自动回复。
        若它替你省下一点时间，或少熬一个调图夜，扫码一杯瑞幸请我喝，我的钱有用。
        最后，谢每一个愿意在深夜抬头的人。谢 StarFans 借来思路，Siril 借来配准，StarNet2、DeepSNR、SkySeg 诸作者借来手艺，以及所有把天文工具开源出来的人。无前人搭棚，此营连帐篷都支不起来。
        """, size: 17.5, style: bodyStyle))
        if let qr = AppAssets.attachment("333.png", width: 400) {
            content.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 10)]))
            content.append(qr)
            content.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 8)]))
        }
        article.setContent(content)
    }
}

final class HelpViewController: NSViewController {
    private let article = ArticleTextView()
    private let nav = NSStackView()
    private var sectionRanges: [NSRange] = []

    override func loadView() {
        let root = NSView()
        let title = UI.label("帮助与使用说明", size: 24, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        nav.orientation = .horizontal
        nav.spacing = 6
        nav.translatesAutoresizingMaskIntoConstraints = false
        article.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)
        root.addSubview(nav)
        root.addSubview(article)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            nav.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            nav.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            nav.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            article.topAnchor.constraint(equalTo: nav.bottomAnchor, constant: 10),
            article.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            article.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            article.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        self.view = root

        let sections: [(String, String, String?)] = [
            ("快速开始", """
            1. 在左侧选择工作区：首页、星空堆栈、星轨、星空延时、全景接片、窄带或工具箱。
            2. 用“导入…”按钮添加图像；列表支持多选、移除和清空。
            3. 设置输出格式与路径，点击右上角的开始按钮。
            4. 下方日志会显示读取、对齐、堆栈、写入的进度；右侧预览会自动拉伸显示结果。

            星空堆栈是最常用的入口。建议先导入亮场，确认参考帧（参考列的单选按钮），再决定是否需要偏置、暗场和平场。
            """, "help-stack.png"),
            ("星空堆栈", """
            普通模式适合快速出图；专业模式会默认打开坏点校正、裁切和背景归一化；深空模式默认全图堆栈并关闭镜头校正。方法可以选择 Sigma 裁剪、均值、中值、最大值或最小值。

            Sigma 预设对应三档常用策略：2σ/3σ 强力去除飞机卫星、4σ/5σ 常规、6σ/6σ 保留流星。参考帧决定输出几何和星点对齐的目标。

            天地分离会使用 SkySeg 计算天空蒙版，也可以勾选“使用手动天空蒙版”并选择一张黑白图（白色代表天空）。天空只参与堆栈，地景保留参考帧。
            """, nil),
            ("星轨", """
            导入连续帧后选择最大值合成；固定地景适合三脚架不动的场景。动态地景会先按星点对齐再做合成。勾选“去除飞机/卫星轨迹”会用直线检测屏蔽单帧中的长亮线。

            暗角/畸变可以使用手动滑块，辉光会给亮轨迹加一层柔光。输出建议 TIFF 16-bit。
            """, "help-trails.png"),
            ("星空延时", """
            导入连续帧，选择去闪窗口（关闭、默认 15、强力 31）和帧率。输出为 H.264 MP4；勾选“导出关键帧”可以同时保存 PNG 序列。

            去闪是在拉伸之前按帧背景亮度做平滑校正，能压住日落或云层造成的明暗跳动。
            """, nil),
            ("全景接片", """
            导入有重叠区域的帧，选择参考帧。程序会用星点配准把每帧变换到参考坐标系，自动扩展画布并做羽化加权融合。夜间全景建议相邻帧重叠 25% 以上。
            """, nil),
            ("窄带", """
            分别选择 Ha、OIII、SII 通道。SHO 是哈勃调色（R=SII、G=Ha、B=OIII），HOO 适合双窄带，HSO 可做另一种配色。三个通道会先做背景扣除和共同归一化，再联动拉伸，颜色不会互相盖掉。

            勾选 StarNet2 去星可以得到纯发射星云的星云层，星点会单独保留在内部结果里。
            """, nil),
            ("工具箱", """
            星点分离｜合成、降噪、天地分离、白平衡校正、缩星｜星柔、图像增强都在这里。先选输入图像，调整参数，点击“运行”；“另存为…”保存当前预览。

            图像增强包含局部对比、结构、天光和星轨辉光；勾选“仅作用于天空”时，地面像素保持不变。
            """, "help-toolbox.png"),
            ("项目与镜头", """
            文件菜单可以保存/打开 .starproject 项目，项目的路径和参数会一起保存。普通/专业模式默认按 EXIF 自动匹配 lensfun，也可以手动加载 Adobe LCP；深空模式默认关闭镜头校正，避免和平场重复。自动匹配失败时，直接用暗角/畸变滑块即可。
            """, nil),
            ("快捷键与贴士", """
            ⌘O 打开项目，⌘S 保存项目，⌘W 关闭窗口，⌘Q 退出。
            大图堆栈会比较吃内存，建议先裁切或使用“裁切到帧重叠区域”。夜景天地分离如果 SkySeg 不理想，手动黑白蒙版最稳。
            处理过程中窗口可以继续操作，但同一工作区不要重复点击开始。
            """, nil),
        ]

        let content = NSMutableAttributedString()
        for (index, section) in sections.enumerated() {
            let range = NSRange(location: content.length, length: 0)
            sectionRanges.append(range)
            content.append(articleText(section.0 + "\n", size: 19, weight: .semibold,
                                       style: {
                                           let s = articleStyle(); s.paragraphSpacing = 8; return s
                                       }()))
            content.append(articleText(section.1))
            if let imageName = section.2, let image = AppAssets.attachment(imageName, width: 560) {
                content.append(image)
                content.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 8)]))
            }
            if index < sections.count - 1 {
                content.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 8)]))
            }
        }
        article.setContent(content)

        for (index, section) in sections.enumerated() {
            let button = NSButton(title: section.0, target: self, action: #selector(jump(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.controlSize = .small
            nav.addArrangedSubview(button)
        }
    }

    @objc private func jump(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < sectionRanges.count else { return }
        let range = sectionRanges[sender.tag]
        article.textView.scrollRangeToVisible(NSRange(location: range.location, length: 1))
    }
}
