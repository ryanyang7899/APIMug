import AppKit

/// 每日用量折线图（纯代码绘制，紧凑高度，用于菜单栏弹窗）
final class DailyUsageChartView: NSView {
    private let data: [(day: String, value: Double)]

    /// width 固定以匹配菜单宽度；height 保持紧凑
    init(data: [(day: String, value: Double)], width: CGFloat = 240, height: CGFloat = 90) {
        self.data = data
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
    }
}
