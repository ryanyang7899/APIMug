import AppKit

/// 每日用量折线图（纯代码绘制，紧凑高度，用于菜单栏弹窗）。
/// 鼠标悬停时高亮最近的数据点，并弹出该日用量气泡。
final class DailyUsageChartView: NSView {
    private let data: [(day: String, value: Double)]
    private let symbol: String

    private var hoverTimer: Timer?
    private var hoveredIndex: Int? {
        didSet {
            if hoveredIndex != oldValue { needsDisplay = true }
        }
    }

    /// width 固定以匹配菜单宽度；height 保持紧凑
    init(data: [(day: String, value: Double)], width: CGFloat = 240, height: CGFloat = 90,
         symbol: String = "¥") {
        self.data = data
        self.symbol = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        hoverTimer?.invalidate()
    }

    /// 视图进入窗口（菜单弹出）时启动悬停轮询，离开时停止
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startHoverTracking()
        } else {
            stopHoverTracking()
        }
    }

    private func startHoverTracking() {
        stopHoverTracking()
        let t = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.pollMouse()
        }
        RunLoop.main.add(t, forMode: .common)
        hoverTimer = t
    }

    private func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    /// 轮询鼠标位置，找出最近的数据点
    private func pollMouse() {
        guard let window = window else { return }
        let screen = NSEvent.mouseLocation
        let local = convert(window.convertPoint(fromScreen: screen), from: nil)
        guard bounds.contains(local), !data.isEmpty else {
            hoveredIndex = nil
            return
        }
        let n = data.count
        let padL: CGFloat = 8, padR: CGFloat = 8
        let plotW = bounds.width - padL - padR
        var nearest = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for i in 0..<n {
            let px = padL + plotW * (n == 1 ? 0.5 : CGFloat(i) / CGFloat(n - 1))
            let d = abs(px - local.x)
            if d < bestDist { bestDist = d; nearest = i }
        }
        hoveredIndex = nearest
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext, !data.isEmpty else { return }

        let w = bounds.width
        let h = bounds.height
        let padL: CGFloat = 8, padR: CGFloat = 8
        let padT: CGFloat = 16   // 顶部放标题
        let padB: CGFloat = 16   // 底部放日期
        let plotW = w - padL - padR
        let plotH = h - padT - padB

        let maxV = max(1, data.map { $0.value }.max() ?? 0)
        let n = data.count

        func xPos(_ i: Int) -> CGFloat {
            padL + plotW * (n == 1 ? 0.5 : CGFloat(i) / CGFloat(n - 1))
        }
        func yPos(_ v: Double) -> CGFloat {
            padT + plotH * (1 - CGFloat(v) / maxV)
        }

        // —— 网格：3 条水平线 ——
        ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1)
        for i in 0...2 {
            let y = padT + plotH * (1 - CGFloat(i) / 2)
            ctx.move(to: CGPoint(x: padL, y: y))
            ctx.addLine(to: CGPoint(x: w - padR, y: y))
            ctx.strokePath()
        }

        let points = data.enumerated().map { CGPoint(x: xPos($0.offset), y: yPos($0.element.value)) }

        // —— 面积填充 ——
        let fill = CGMutablePath()
        fill.move(to: CGPoint(x: points[0].x, y: padT))
        for p in points { fill.addLine(to: p) }
        fill.addLine(to: CGPoint(x: points[n - 1].x, y: padT))
        fill.closeSubpath()
        ctx.addPath(fill)
        ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor)
        ctx.fillPath()

        // —— 折线 ——
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: points[0])
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()

        // —— 数据点 ——
        ctx.setFillColor(NSColor.controlAccentColor.cgColor)
        for p in points {
            ctx.fillEllipse(in: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5))
        }

        // —— 标题（左上角）——
        let title = NSAttributedString(string: "近 7 日用量", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        title.draw(at: CGPoint(x: padL, y: h - 13))

        // —— 底部日期标签（MM-dd，今天突出）——
        for (i, item) in data.enumerated() {
            let isToday = i == n - 1
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8.5, weight: isToday ? .semibold : .regular),
                .foregroundColor: isToday ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            let label = NSAttributedString(string: String(item.day.dropFirst(5)), attributes: attrs)
            let size = label.size()
            label.draw(at: CGPoint(x: xPos(i) - size.width / 2, y: 5))
        }

        // —— 悬停高亮 + 用量气泡 ——
        if let hi = hoveredIndex, hi >= 0, hi < n {
            let p = points[hi]
            // 竖参考线
            ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.move(to: CGPoint(x: p.x, y: padT))
            ctx.addLine(to: CGPoint(x: p.x, y: padT + plotH))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])

            // 高亮数据点
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))

            // 气泡：日期 + 用量
            let dateStr = String(data[hi].day.dropFirst(5))
            let valueStr = "\(symbol)\(String(format: "%.2f", data[hi].value))"
            let dateAttr = NSAttributedString(string: dateStr, attributes: [
                .font: NSFont.systemFont(ofSize: 9),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let valueAttr = NSAttributedString(string: valueStr, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ])
            let bubbleW = max(dateAttr.size().width, valueAttr.size().width) + 16
            let bubbleH: CGFloat = 32
            var bx = p.x - bubbleW / 2
            var by = p.y - bubbleH - 5
            bx = min(max(bx, 2), w - bubbleW - 2)
            by = max(by, padT - 4)

            let bubbleRect = NSRect(x: bx, y: by, width: bubbleW, height: bubbleH)
            let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 6, yRadius: 6)
            NSColor.controlBackgroundColor.setFill()
            bubble.fill()
            NSColor.separatorColor.setStroke()
            bubble.lineWidth = 1
            bubble.stroke()

            let dateSize = dateAttr.size()
            let valueSize = valueAttr.size()
            let textX = bx + (bubbleW - valueSize.width) / 2
            dateAttr.draw(at: NSPoint(x: bx + (bubbleW - dateSize.width) / 2, y: by + 17))
            valueAttr.draw(at: NSPoint(x: textX, y: by + 5))
        }
    }
}
