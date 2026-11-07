import AppKit

/// A scrolling real-time chart: one line, or several stacked areas, on one axis.
final class TimeSeriesChartView: HoverableView {
    struct Series {
        var name: String
        var color: NSColor
    }

    /// A vertical annotation. The line takes `color` from this point on.
    struct Marker {
        var time: TimeInterval
        var label: String
        var color: NSColor?
    }

    var series: [Series] = []
    var isStacked = false
    var windowSeconds: TimeInterval = 60
    var unit = "GB/s"
    /// Samples further apart than this are shown as a break in the data.
    var gapSeconds: TimeInterval = 0.5
    var emptyMessage = ""

    private var times: [TimeInterval] = []
    private var values: [[Double]] = []
    private var markers: [Marker] = []
    private var axisMax = 1.0
    private var clock: TimeInterval = 0

    func append(time: TimeInterval, values sample: [Double]) {
        times.append(time)
        values.append(sample)
        clock = time
        let oldest = time - windowSeconds - 1
        if let first = times.firstIndex(where: { $0 >= oldest }), first > 0 {
            times.removeFirst(first)
            values.removeFirst(first)
        }
        markers.removeAll { $0.time < oldest }
        updateAxis()
        needsDisplay = true
    }

    func addMarker(_ marker: Marker) {
        if let last = markers.last, marker.time - last.time < 0.001 { markers.removeLast() }
        markers.append(marker)
        needsDisplay = true
    }

    func clear() {
        times.removeAll()
        values.removeAll()
        markers.removeAll()
        axisMax = 1
        needsDisplay = true
    }

    private func total(_ sample: [Double]) -> Double {
        isStacked ? sample.reduce(0, +) : (sample.max() ?? 0)
    }

    private func updateAxis() {
        let top = values.map(total).max() ?? 1
        axisMax = Scale.niceCeiling(max(top * 1.08, 0.01))
    }

    private var plot: CGRect {
        let topPadding: CGFloat = isStacked ? 36 : 22
        return CGRect(x: 40, y: topPadding, width: max(1, bounds.width - 46), height: max(1, bounds.height - topPadding - 22))
    }

    private func x(_ time: TimeInterval, _ plot: CGRect) -> CGFloat {
        plot.maxX - CGFloat((clock - time) / windowSeconds) * plot.width
    }

    private func y(_ value: Double, _ plot: CGRect) -> CGFloat {
        plot.maxY - CGFloat(min(1, value / axisMax)) * plot.height
    }

    override func draw(_ dirtyRect: NSRect) {
        let plot = plot
        drawAxes(plot)
        if times.isEmpty {
            if !emptyMessage.isEmpty {
                Ink.draw(emptyMessage, at: CGPoint(x: plot.midX, y: plot.midY - 8), font: Theme.text(13), color: Theme.inkMuted, align: .center)
            }
            return
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: plot.insetBy(dx: 0, dy: -2)).addClip()
        if isStacked { drawStacked(plot) } else { drawLine(plot) }
        drawMarkers(plot)
        NSGraphicsContext.restoreGraphicsState()
        if isStacked { drawLegend() }
        drawHover(plot)
    }

    private func drawAxes(_ plot: CGRect) {
        let step = Scale.tickStep(max: axisMax, count: 4)
        var tick = 0.0
        while tick <= axisMax + step * 0.001 {
            let lineY = y(tick, plot)
            (tick == 0 ? Theme.axis : Theme.grid).setFill()
            CGRect(x: plot.minX, y: lineY, width: plot.width, height: 1).fill()
            Ink.draw(Scale.tickLabel(tick), at: CGPoint(x: plot.minX - 6, y: lineY - 7), font: Theme.digits(10.5), color: Theme.inkMuted, align: .right)
            tick += step
        }
        Ink.draw(unit, at: CGPoint(x: plot.minX - 6, y: plot.minY - 22), font: Theme.text(10), color: Theme.inkMuted, align: .right)
        let stepSeconds = windowSeconds / 4
        for index in 0...4 {
            let seconds = stepSeconds * Double(index)
            let label = index == 0 ? "now" : seconds >= 60 ? "\(Int(seconds / 60))m" : "\(Int(seconds))s"
            let tickX = plot.maxX - plot.width * CGFloat(index) / 4
            Ink.draw(label, at: CGPoint(x: tickX, y: plot.maxY + 5), font: Theme.digits(10.5), color: Theme.inkMuted, align: index == 0 ? .right : index == 4 ? .left : .center)
        }
    }

    private func drawLine(_ plot: CGRect) {
        let visible = times.indices.filter { times[$0] >= clock - windowSeconds - 0.5 }
        guard !visible.isEmpty else { return }

        // Consecutive samples of one colour form a run; a gap or marker starts another.
        var runStart = visible[0]
        var markerIndex = markers.firstIndex { $0.time > times[runStart] } ?? markers.count
        var color = series.first?.color ?? Theme.blue
        for marker in markers where marker.time <= times[runStart] { color = marker.color ?? color }

        func flush(_ start: Int, _ end: Int, _ color: NSColor) {
            let line = NSBezierPath()
            for index in start...end {
                let point = CGPoint(x: x(times[index], plot), y: y(values[index].first ?? 0, plot))
                index == start ? line.move(to: point) : line.line(to: point)
            }
            line.lineWidth = 2
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            if end > start {
                let area = line.copy() as! NSBezierPath
                area.line(to: CGPoint(x: x(times[end], plot), y: plot.maxY))
                area.line(to: CGPoint(x: x(times[start], plot), y: plot.maxY))
                area.close()
                NSGradient(starting: color.withAlphaComponent(0.26), ending: color.withAlphaComponent(0.02))?.draw(in: area, angle: 90)
            }
            color.setStroke()
            line.stroke()
        }

        for position in visible.dropFirst() {
            let previous = position - 1
            let hasGap = times[position] - times[previous] > gapSeconds
            let crossesMarker = markerIndex < markers.count && markers[markerIndex].time <= times[position]
            if hasGap || crossesMarker {
                flush(runStart, previous, color)
                while markerIndex < markers.count && markers[markerIndex].time <= times[position] {
                    color = markers[markerIndex].color ?? color
                    markerIndex += 1
                }
                runStart = position
            }
        }
        flush(runStart, visible.last!, color)
    }

    private func drawStacked(_ plot: CGRect) {
        // Each uninterrupted stretch is drawn separately so gaps stay honest.
        var start = 0
        while start < times.count {
            var end = start
            while end + 1 < times.count, times[end + 1] - times[end] <= gapSeconds { end += 1 }
            if end > start { drawBands(from: start, to: end, plot) }
            start = end + 1
        }
    }

    private func drawBands(from start: Int, to end: Int, _ plot: CGRect) {
        var lower = [Double](repeating: 0, count: end - start + 1)
        for (seriesIndex, item) in series.enumerated() {
            let upper = (start...end).enumerated().map { offset, index in
                lower[offset] + (seriesIndex < values[index].count ? values[index][seriesIndex] : 0)
            }
            let band = NSBezierPath()
            for offset in upper.indices {
                let point = CGPoint(x: x(times[start + offset], plot), y: y(upper[offset], plot))
                offset == 0 ? band.move(to: point) : band.line(to: point)
            }
            let topEdge = band.copy() as! NSBezierPath
            for offset in lower.indices.reversed() {
                band.line(to: CGPoint(x: x(times[start + offset], plot), y: y(lower[offset], plot)))
            }
            band.close()
            item.color.withAlphaComponent(0.8).setFill()
            band.fill()
            // A surface-coloured seam separates bands without outlining them.
            Theme.surface.setStroke()
            topEdge.lineWidth = 2
            topEdge.stroke()
            lower = upper
        }
    }

    private func drawMarkers(_ plot: CGRect) {
        var labelFloor: CGFloat = plot.minX
        for marker in markers {
            let markerX = x(marker.time, plot)
            guard markerX >= plot.minX else { continue }
            Theme.axis.setFill()
            CGRect(x: markerX, y: plot.minY, width: 1, height: plot.height).fill()
            let font = Theme.text(10)
            let width = Ink.width(marker.label, font: font)
            // Labels too close to the previous one are left out, not overlapped.
            if markerX + 4 >= labelFloor, markerX + width + 8 < plot.maxX {
                Ink.draw(marker.label, at: CGPoint(x: markerX + 4, y: plot.minY), font: font, color: Theme.inkMuted)
                labelFloor = markerX + width + 12
            }
        }
    }

    private func drawLegend() {
        let font = Theme.text(11)
        var legendX: CGFloat = 40
        let latest = values.last ?? []
        for (index, item) in series.enumerated() {
            item.color.setFill()
            NSBezierPath(ovalIn: CGRect(x: legendX, y: 5, width: 8, height: 8)).fill()
            let value = index < latest.count ? " \(Format.watts(latest[index]))" : ""
            let size = Ink.draw(item.name + value, at: CGPoint(x: legendX + 12, y: 1.5), font: font, color: Theme.inkSecondary)
            legendX += 12 + size.width + 14
        }
    }

    private func drawHover(_ plot: CGRect) {
        guard let hover = hoverPoint, plot.contains(hover), !times.isEmpty else { return }
        let time = clock - Double((plot.maxX - hover.x) / plot.width) * windowSeconds
        guard let nearest = times.indices.min(by: { abs(times[$0] - time) < abs(times[$1] - time) }),
              abs(times[nearest] - time) <= max(1, gapSeconds) else { return }
        let lineX = x(times[nearest], plot)
        Theme.inkMuted.setFill()
        CGRect(x: lineX, y: plot.minY, width: 1, height: plot.height).fill()
        let ago = clock - times[nearest]
        var lines: [(dot: NSColor?, text: String)] = [(nil, ago < 0.5 ? "now" : String(format: "%.0f s ago", ago))]
        if isStacked {
            for (index, item) in series.enumerated() where index < values[nearest].count {
                lines.append((item.color, "\(item.name)  \(Format.number(values[nearest][index])) \(unit)"))
            }
            lines.append((nil, "Total  \(Format.number(values[nearest].reduce(0, +))) \(unit)"))
        } else {
            lines.append((nil, "\(Format.number(values[nearest].first ?? 0)) \(unit)"))
        }
        Ink.tooltip(lines: lines, near: CGPoint(x: lineX, y: hover.y), in: bounds)
    }
}
