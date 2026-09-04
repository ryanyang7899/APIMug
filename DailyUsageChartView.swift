import AppKit

/// 每个协议类型分配一个固定图表颜色（同一张图里多站点区分）
extension ProviderType {
    var chartColor: NSColor {
        switch self {
        case .deepseek:   return .systemBlue
        case .kimi:       return .systemPurple
        case .stepfun:    return .systemOrange
        case .deepinfra:  return .systemTeal
        case .openrouter: return .systemPink
        case .newapi:     return .systemGray
        case .lbqh:       return .systemBrown
        }
    }
}

/// 每日用量折线图（纯代码绘制，紧凑高度，用于菜单栏弹窗）。
/// 支持多站点多色线条：每站点一条线，图例在顶部，悬停显示各站点当日用量。
final class DailyUsageChartView: NSView {
    struct Series {
        let name: String
        let color: NSColor
        let points: [(day: String, value: Double)]
    }

    private let series: [Series]
    private let symbol: String

    private var hoverTimer: Timer?
    private var hoveredIndex: Int? {
        didSet {
            if hoveredIndex != oldValue { needsDisplay = true }
        }
    }

    /// width 由调用方按菜单宽度给定（保证左右等距居中）；height 保持紧凑
    init(series: [Series], width: CGFloat = 240, height: CGFloat = 100,
         symbol: String = "¥") {
        self.series = series
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

    /// 轮询鼠标位置，找出最近的横坐标下标
    private func pollMouse() {
        guard let window = window else { return }
        let screen = NSEvent.mouseLocation
        let local = convert(window.convertPoint(fromScreen: screen), from: nil)
        let n = series.map { $0.points.count }.max() ?? 0
        guard bounds.contains(local), n > 0 else {
            hoveredIndex = nil
            return
        }
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
        guard let ctx = NSGraphicsContext.current?.cgContext, !series.isEmpty else { return }

        let w = bounds.width
        let h = bounds.height
        let padL: CGFloat = 8, padR: CGFloat = 8
        let padT: CGFloat = 22   // 顶部放图例
        let padB: CGFloat = 16   // 底部放日期
        let plotW = w - padL - padR
        let plotH = h - padT - padB
        let n = series.map { $0.points.count }.max() ?? 0
        guard n > 0 else { return }

        // 非翻转坐标系：值越大 y 越大（越靠上）
        let maxV = max(1, series.flatMap { $0.points.map { $0.value } }.max() ?? 0)
        func xPos(_ i: Int) -> CGFloat {
            padL + plotW * (n == 1 ? 0.5 : CGFloat(i) / CGFloat(n - 1))
        }
        func yPos(_ v: Double) -> CGFloat {
            padT + plotH * (CGFloat(v) / maxV)
        }

        // —— 网格：3 条水平线（0% / 50% / 100%）——
        ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1)
        for i in 0...2 {
            let y = padT + plotH * (CGFloat(i) / 2)
            ctx.move(to: CGPoint(x: padL, y: y))
            ctx.addLine(to: CGPoint(x: w - padR, y: y))
            ctx.strokePath()
        }

        // —— 每条线：仅折线 + 数据点（无面积填充）——
        for s in series {
            let pts = s.points.enumerated().map { CGPoint(x: xPos($0.offset), y: yPos($0.element.value)) }
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(2)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: pts[0])
            for p in pts.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()

            ctx.setFillColor(s.color.cgColor)
            for p in pts {
                ctx.fillEllipse(in: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5))
            }
        }

        // —— 图例（顶部）：色点 + 站点名 ——
        var lx: CGFloat = padL
        for s in series {
            ctx.setFillColor(s.color.cgColor)
            ctx.fillEllipse(in: CGRect(x: lx, y: h - 13, width: 6, height: 6))
            let name = NSAttributedString(string: s.name, attributes: [
                .font: NSFont.systemFont(ofSize: 8.5),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
            let size = name.size()
            name.draw(at: CGPoint(x: lx + 8, y: h - 14))
            lx += 8 + size.width + 10
        }

        // —— 底部日期标签（MM-dd，今天突出）——
        let firstPoints = series.first?.points ?? []
        for (i, item) in firstPoints.enumerated() {
            let isToday = i == n - 1
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8.5, weight: isToday ? .semibold : .regular),
                .foregroundColor: isToday ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ]
            let label = NSAttributedString(string: String(item.day.dropFirst(5)), attributes: attrs)
            let size = label.size()
            label.draw(at: CGPoint(x: xPos(i) - size.width / 2, y: 5))
        }

        // —— 悬停：竖参考线 + 各站点当日用量气泡 ——
        if let hi = hoveredIndex, hi >= 0, hi < n {
            let px = xPos(hi)

            ctx.setStrokeColor(NSColor.secondaryLabelColor.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.move(to: CGPoint(x: px, y: padT))
            ctx.addLine(to: CGPoint(x: px, y: padT + plotH))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])

            // 高亮该日各站点数据点
            for s in series {
                let p = CGPoint(x: px, y: yPos(s.points[hi].value))
                ctx.setFillColor(s.color.cgColor)
                ctx.fillEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
            }

            // 气泡：日期 + 每个站点一行「名称 用量」
            let dateStr = String((series.first?.points[hi].day ?? "").dropFirst(5))
            var lines: [(text: String, color: NSColor)] = [(dateStr, .secondaryLabelColor)]
            for s in series {
                let v = s.points[hi].value
                lines.append(("\(s.name)  \(symbol)\(String(format: "%.2f", v))", s.color))
            }
            var bubbleW: CGFloat = 0
            var bubbleH: CGFloat = 6
            for (text, _) in lines {
                let tw = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width + 16
                bubbleW = max(bubbleW, tw)
                bubbleH += 14
            }
            bubbleH += 4

            var bx = px - bubbleW / 2
            bx = min(max(bx, 2), w - bubbleW - 2)
            // 气泡在绘图区内垂直居中，避免溢出
            var by = padT + (plotH - bubbleH) / 2
            by = min(max(by, 2), h - bubbleH - 2)
            if by < padT { by = padT + 2 }

            let bubbleRect = NSRect(x: bx, y: by, width: bubbleW, height: bubbleH)
            let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 6, yRadius: 6)
            NSColor.controlBackgroundColor.setFill()
            bubble.fill()
            NSColor.separatorColor.setStroke()
            bubble.lineWidth = 1
            bubble.stroke()

            var ty = by + bubbleH - 14
            for (text, color) in lines {
                let isDate = color == NSColor.secondaryLabelColor
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: isDate ? .regular : .medium),
                    .foregroundColor: color,
                ]
                let t = NSAttributedString(string: text, attributes: attrs)
                let size = t.size()
                t.draw(at: CGPoint(x: bx + (bubbleW - size.width) / 2, y: ty))
                ty -= 14
            }
        }
    }
}
