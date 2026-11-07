import AppKit

/// A line chart over a discrete X axis, used for block-size curves and thread scaling.
final class CurveChartView: HoverableView {
    struct Series {
        var name: String
        var color: NSColor
        /// Values by index into `xLabels`; nil where nothing was measured.
        var values: [Double?]
        var isReference = false
    }

    struct Guide {
        var index: Double
        var label: String
    }

    var xLabels: [String] = [] { didSet { needsDisplay = true } }
    var xTitle = "" { didSet { needsDisplay = true } }
    var series: [Series] = [] { didSet { needsDisplay = true } }
    var guides: [Guide] = [] { didSet { needsDisplay = true } }
    var selectedIndex: Int? { didSet { needsDisplay = true } }
    var emptyMessage = "" { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?

    private var plot: CGRect {
        CGRect(x: 44, y: 28, width: max(1, bounds.width - 54), height: max(1, bounds.height - 28 - 38))
    }

    /// Reference lines stay within the axis set by the measurements.
    private var axisMax: Double {
        let top = series.filter { !$0.isReference }.flatMap { $0.values.compactMap { $0 } }.max() ?? 1
        return Scale.niceCeiling(top * 1.08)
    }

    private func x(_ index: Double, _ plot: CGRect) -> CGFloat {
        let intervals = max(1, xLabels.count - 1)
        return plot.minX + plot.width * CGFloat(index) / CGFloat(intervals)
    }

    private func y(_ value: Double, _ plot: CGRect, _ axisMax: Double) -> CGFloat {
        plot.maxY - plot.height * CGFloat(value / axisMax)
    }

    private func index(at point: CGPoint, _ plot: CGRect) -> Int? {
        guard !xLabels.isEmpty, point.x >= plot.minX - 12, point.x <= plot.maxX + 12 else { return nil }
        let ratio = Double((point.x - plot.minX) / plot.width) * Double(xLabels.count - 1)
        return min(xLabels.count - 1, max(0, Int(ratio.rounded())))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = index(at: point, plot) { onSelect?(index) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = plot
        let axisMax = axisMax
        let measured = series.contains { !$0.isReference && $0.values.contains { $0 != nil } }

        let step = Scale.tickStep(max: axisMax, count: 4)
        var tick = 0.0
        while tick <= axisMax + step * 0.001 {
            let lineY = y(tick, plot, axisMax)
            (tick == 0 ? Theme.axis : Theme.grid).setFill()
            CGRect(x: plot.minX, y: lineY, width: plot.width, height: 1).fill()
            if measured {
                Ink.draw(Scale.tickLabel(tick), at: CGPoint(x: plot.minX - 6, y: lineY - 7), font: Theme.digits(10.5), color: Theme.inkMuted, align: .right)
            }
            tick += step
        }
        if measured {
            Ink.draw("GB/s", at: CGPoint(x: plot.minX - 6, y: plot.minY - 21), font: Theme.text(10), color: Theme.inkMuted, align: .right)
        }

        // Thin out labels to whatever fits.
        let font = Theme.digits(10.5)
        let widest = xLabels.map { Ink.width($0, font: font) }.max() ?? 0
        let every = max(1, Int(ceil((widest + 10) / max(1, plot.width / CGFloat(max(1, xLabels.count - 1))))))
        for (index, label) in xLabels.enumerated() where index % every == 0 {
            Ink.draw(label, at: CGPoint(x: x(Double(index), plot), y: plot.maxY + 5), font: font, color: Theme.inkMuted, align: .center)
        }
        Ink.draw(xTitle, at: CGPoint(x: plot.midX, y: plot.maxY + 20), font: Theme.text(10.5), color: Theme.inkMuted, align: .center)

        guard measured else {
            if !emptyMessage.isEmpty {
                Ink.draw(emptyMessage, at: CGPoint(x: plot.midX, y: plot.midY - 8), font: Theme.text(13), color: Theme.inkMuted, align: .center)
            }
            return
        }

        for guide in guides {
            let guideX = x(guide.index, plot)
            Theme.axis.setFill()
            CGRect(x: guideX, y: plot.minY, width: 1, height: plot.height).fill()
            Ink.draw(guide.label, at: CGPoint(x: guideX + 4, y: plot.minY), font: Theme.text(10), color: Theme.inkMuted)
        }
        if let selectedIndex {
            let selectedX = x(Double(selectedIndex), plot)
            Theme.inkMuted.withAlphaComponent(0.5).setFill()
            CGRect(x: selectedX, y: plot.minY, width: 1, height: plot.height).fill()
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot.insetBy(dx: -6, dy: -6)).addClip()
        for item in series { drawSeries(item, plot, axisMax) }
        NSGraphicsContext.restoreGraphicsState()
        drawLegend()
        drawHover(plot, axisMax)
    }

    private func drawSeries(_ item: Series, _ plot: CGRect, _ axisMax: Double) {
        let line = NSBezierPath()
        var isDrawing = false
        for (index, value) in item.values.enumerated() {
            guard let value else { isDrawing = false; continue }
            let point = CGPoint(x: x(Double(index), plot), y: y(value, plot, axisMax))
            isDrawing ? line.line(to: point) : line.move(to: point)
            isDrawing = true
        }
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        if item.isReference {
            line.lineWidth = 1
            line.setLineDash([3, 3], count: 2, phase: 0)
            Theme.inkMuted.setStroke()
            line.stroke()
            return
        }
        line.lineWidth = 2
        item.color.setStroke()
        line.stroke()
        for (index, value) in item.values.enumerated() {
            guard let value else { continue }
            let point = CGPoint(x: x(Double(index), plot), y: y(value, plot, axisMax))
            Theme.surface.setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
            item.color.setFill()
            NSBezierPath(ovalIn: CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)).fill()
        }
    }

    private func drawLegend() {
        let visible = series.filter { $0.values.contains { $0 != nil } }
        guard visible.count > 1 else { return }
        var legendX: CGFloat = 44
        for item in visible {
            if item.isReference {
                Theme.inkMuted.setFill()
                CGRect(x: legendX, y: 8, width: 8, height: 1).fill()
            } else {
                item.color.setFill()
                NSBezierPath(ovalIn: CGRect(x: legendX, y: 4, width: 8, height: 8)).fill()
            }
            let size = Ink.draw(item.name, at: CGPoint(x: legendX + 12, y: 1), font: Theme.text(11), color: Theme.inkSecondary)
            legendX += 12 + size.width + 14
        }
    }

    private func drawHover(_ plot: CGRect, _ axisMax: Double) {
        guard let hover = hoverPoint, let index = index(at: hover, plot) else { return }
        let lineX = x(Double(index), plot)
        Theme.inkMuted.setFill()
        CGRect(x: lineX, y: plot.minY, width: 1, height: plot.height).fill()
        var lines: [(dot: NSColor?, text: String)] = [(nil, xLabels[index])]
        for item in series where index < item.values.count {
            if let value = item.values[index] {
                lines.append((item.isReference ? nil : item.color, "\(item.name)  \(Format.rate(value))"))
            }
        }
        guard lines.count > 1 else { return }
        Ink.tooltip(lines: lines, near: CGPoint(x: lineX, y: hover.y), in: bounds)
    }
}

/// Bandwidth across block size and thread count, on a single-hue ramp.
final class HeatmapView: HoverableView {
    struct Cell: Hashable {
        var column: Int
        var row: Int
    }

    var columns: [String] = [] { didSet { needsDisplay = true } }
    var rows: [String] = [] { didSet { needsDisplay = true } }
    var values: [Cell: Double] = [:] { didSet { needsDisplay = true } }
    var skipped: Set<Cell> = [] { didSet { needsDisplay = true } }
    var selected: Cell? { didSet { needsDisplay = true } }
    var active: Cell? { didSet { needsDisplay = true } }
    var emptyMessage = "" { didSet { needsDisplay = true } }
    var onSelect: ((Cell) -> Void)?

    private var plot: CGRect {
        CGRect(x: 30, y: 4, width: max(1, bounds.width - 30 - 62), height: max(1, bounds.height - 4 - 36))
    }

    private func cell(at point: CGPoint) -> Cell? {
        let plot = plot
        guard plot.contains(point), !columns.isEmpty, !rows.isEmpty else { return nil }
        let column = Int((point.x - plot.minX) / plot.width * CGFloat(columns.count))
        // Thread count rises up the chart, like the Y axis of the other charts.
        let row = rows.count - 1 - Int((point.y - plot.minY) / plot.height * CGFloat(rows.count))
        return Cell(column: min(columns.count - 1, column), row: max(0, row))
    }

    private func rect(_ cell: Cell, _ plot: CGRect) -> CGRect {
        let width = plot.width / CGFloat(columns.count)
        let height = plot.height / CGFloat(rows.count)
        return CGRect(
            x: plot.minX + CGFloat(cell.column) * width,
            y: plot.minY + CGFloat(rows.count - 1 - cell.row) * height,
            width: width,
            height: height
        ).insetBy(dx: 1, dy: 1)
    }

    override func mouseDown(with event: NSEvent) {
        if let cell = cell(at: convert(event.locationInWindow, from: nil)) { onSelect?(cell) }
    }

    /// Bandwidth spans three orders of magnitude from L1 to DRAM, so colour uses a log scale.
    private func fraction(_ value: Double, low: Double, high: Double) -> Double {
        guard high > low, value > 0 else { return 1 }
        return (log(value) - log(low)) / (log(high) - log(low))
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = plot
        let low = values.values.min() ?? 0
        let high = values.values.max() ?? 1
        for column in columns.indices {
            for row in rows.indices {
                let cell = Cell(column: column, row: row)
                let cellRect = rect(cell, plot)
                let path = NSBezierPath(roundedRect: cellRect, xRadius: 2, yRadius: 2)
                if let value = values[cell] {
                    Theme.rampColor(fraction(value, low: low, high: high)).setFill()
                    path.fill()
                } else {
                    Theme.raised.setFill()
                    path.fill()
                    if skipped.contains(cell) {
                        let cross = NSBezierPath()
                        cross.move(to: CGPoint(x: cellRect.minX + 3, y: cellRect.maxY - 3))
                        cross.line(to: CGPoint(x: cellRect.maxX - 3, y: cellRect.minY + 3))
                        cross.lineWidth = 1
                        Theme.inkMuted.setStroke()
                        cross.stroke()
                    }
                }
            }
        }
        for (highlight, color, width) in [(selected, Theme.inkPrimary, CGFloat(1.5)), (active, Theme.yellow, CGFloat(2))] {
            guard let highlight, highlight.column < columns.count, highlight.row < rows.count else { continue }
            let path = NSBezierPath(roundedRect: rect(highlight, plot).insetBy(dx: -1, dy: -1), xRadius: 3, yRadius: 3)
            path.lineWidth = width
            color.setStroke()
            path.stroke()
        }

        let font = Theme.digits(10.5)
        let cellHeight = plot.height / CGFloat(max(1, rows.count))
        let rowEvery = cellHeight >= 13 ? 1 : 2
        for (index, label) in rows.enumerated() where index % rowEvery == 0 {
            let labelY = plot.maxY - (CGFloat(index) + 0.5) * cellHeight - 7
            Ink.draw(label, at: CGPoint(x: plot.minX - 6, y: labelY), font: font, color: Theme.inkMuted, align: .right)
        }
        let cellWidth = plot.width / CGFloat(max(1, columns.count))
        let widest = columns.map { Ink.width($0, font: font) }.max() ?? 0
        let columnEvery = max(1, Int(ceil((widest + 8) / cellWidth)))
        for (index, label) in columns.enumerated() where index % columnEvery == 0 {
            Ink.draw(label, at: CGPoint(x: plot.minX + (CGFloat(index) + 0.5) * cellWidth, y: plot.maxY + 4), font: font, color: Theme.inkMuted, align: .center)
        }
        Ink.draw("Block size per thread", at: CGPoint(x: plot.midX, y: plot.maxY + 19), font: Theme.text(10.5), color: Theme.inkMuted, align: .center)

        if !values.isEmpty { drawScale(plot, low: low, high: high) }
        if values.isEmpty, !emptyMessage.isEmpty {
            Ink.draw(emptyMessage, at: CGPoint(x: plot.midX, y: plot.midY - 8), font: Theme.text(13), color: Theme.inkSecondary, align: .center)
        }

        if let hover = hoverPoint, let cell = cell(at: hover) {
            var lines: [(dot: NSColor?, text: String)] = [(nil, "\(columns[cell.column]) · \(rows[cell.row]) threads")]
            if let value = values[cell] {
                lines.append((nil, Format.rate(value)))
            } else {
                lines.append((nil, skipped.contains(cell) ? "Skipped: over memory limit" : "Not measured"))
            }
            Ink.tooltip(lines: lines, near: hover, in: bounds)
        }
    }

    private func drawScale(_ plot: CGRect, low: Double, high: Double) {
        let bar = CGRect(x: bounds.width - 52, y: plot.minY + 14, width: 8, height: max(1, plot.height - 28))
        let segments = Theme.ramp.count
        for index in 0..<segments {
            let height = bar.height / CGFloat(segments)
            Theme.ramp[index].setFill()
            CGRect(x: bar.minX, y: bar.maxY - CGFloat(index + 1) * height, width: bar.width, height: height + 0.5).fill()
        }
        let font = Theme.digits(10.5)
        Ink.draw(Format.number(high), at: CGPoint(x: bar.minX, y: plot.minY - 1), font: font, color: Theme.inkMuted)
        Ink.draw(Format.number(low), at: CGPoint(x: bar.minX, y: bar.maxY + 1), font: font, color: Theme.inkMuted)
        Ink.draw("GB/s", at: CGPoint(x: bar.maxX + 4, y: bar.midY - 7), font: Theme.text(10), color: Theme.inkMuted)
    }
}

/// One thin bar per worker. Uneven bars show core-type spill or scheduling unfairness.
final class ThreadLanesView: HoverableView {
    var values: [Double] = [] {
        didSet {
            let top = values.max() ?? 0
            let wanted = Scale.niceCeiling(max(top, 0.01))
            if wanted > axisMax || wanted < axisMax * 0.4 { axisMax = wanted }
            needsDisplay = true
        }
    }
    var tint: NSColor = Theme.blue { didSet { needsDisplay = true } }
    private var axisMax = 1.0

    private var plot: CGRect {
        CGRect(x: 26, y: 4, width: max(1, bounds.width - 26), height: max(1, bounds.height - 22))
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = plot
        Theme.axis.setFill()
        CGRect(x: plot.minX, y: plot.maxY, width: plot.width, height: 1).fill()
        Theme.grid.setFill()
        CGRect(x: plot.minX, y: plot.minY, width: plot.width, height: 1).fill()
        Ink.draw(Scale.tickLabel(axisMax), at: CGPoint(x: plot.minX - 4, y: plot.minY - 6), font: Theme.digits(10), color: Theme.inkMuted, align: .right)
        Ink.draw("0", at: CGPoint(x: plot.minX - 4, y: plot.maxY - 7), font: Theme.digits(10), color: Theme.inkMuted, align: .right)
        guard !values.isEmpty else {
            Ink.draw("No workers running", at: CGPoint(x: plot.midX, y: plot.midY - 8), font: Theme.text(12), color: Theme.inkMuted, align: .center)
            return
        }
        let slot = plot.width / CGFloat(values.count)
        let barWidth = min(18, max(3, slot - 2))
        for (index, value) in values.enumerated() {
            let height = max(1, plot.height * CGFloat(min(1, value / axisMax)))
            let bar = CGRect(x: plot.minX + slot * CGFloat(index) + (slot - barWidth) / 2, y: plot.maxY - height, width: barWidth, height: height)
            let radius = min(4, min(barWidth, height) / 2)
            tint.setFill()
            NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
            CGRect(x: bar.minX, y: plot.maxY - min(radius, height), width: bar.width, height: min(radius, height)).fill()
            if slot >= 14 {
                Ink.draw("\(index + 1)", at: CGPoint(x: bar.midX, y: plot.maxY + 3), font: Theme.digits(10), color: Theme.inkMuted, align: .center)
            }
        }
        if let hover = hoverPoint, plot.insetBy(dx: 0, dy: -18).contains(hover) {
            let index = min(values.count - 1, max(0, Int((hover.x - plot.minX) / slot)))
            Ink.tooltip(lines: [(nil, "Thread \(index + 1)  \(Format.rate(values[index]))")], near: hover, in: bounds)
        }
    }
}

/// L1 → L2 → SLC/DRAM, with the level the current working set falls into lit up.
final class MemoryLevelView: DrawnView {
    var level: SystemTopology.MemoryLevel = .memory { didSet { needsDisplay = true } }
    var sizes: [String] = [] { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 44) }

    override func draw(_ dirtyRect: NSRect) {
        let levels = SystemTopology.MemoryLevel.allCases
        let gap: CGFloat = 4
        let width = (bounds.width - gap * CGFloat(levels.count - 1)) / CGFloat(levels.count)
        for (index, item) in levels.enumerated() {
            let box = CGRect(x: CGFloat(index) * (width + gap), y: 0, width: width, height: bounds.height)
            let isCurrent = item == level
            (isCurrent ? Theme.inkPrimary : Theme.raised).setFill()
            NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
            Ink.draw(item.name, at: CGPoint(x: box.midX, y: 6), font: Theme.text(11.5, .semibold), color: isCurrent ? Theme.page : Theme.inkSecondary, align: .center)
            if index < sizes.count {
                Ink.draw(sizes[index], at: CGPoint(x: box.midX, y: 23), font: Theme.digits(10), color: isCurrent ? Theme.page.withAlphaComponent(0.72) : Theme.inkMuted, align: .center)
            }
        }
    }
}
