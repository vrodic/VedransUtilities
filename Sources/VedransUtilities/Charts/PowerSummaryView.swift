import AppKit

/// A compact power readout for other tabs: system total with its recent history,
/// then where it goes, using the Power tab's rail colours.
final class PowerSummaryView: DrawnView {
    /// The line under the rails. Who it describes depends on the test running.
    var footnote: (label: String, value: Double?) = ("This app's CPU", nil) { didSet { needsDisplay = true } }
    private var sample: PowerSample?
    private var history: [Double] = []
    private static let historyLength = 120 // 60 seconds at 2 Hz.

    func update(_ sample: PowerSample) {
        self.sample = sample
        if let system = sample.system {
            history.append(system)
            if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        }
        needsDisplay = true
        setAccessibilityLabel("System power \(Format.watts(sample.system))")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let sample, sample.system != nil else {
            Ink.draw("Waiting for sensors", at: CGPoint(x: bounds.midX, y: bounds.midY - 8), font: Theme.text(12), color: Theme.inkMuted, align: .center)
            return
        }
        Ink.draw(Format.watts(sample.system), at: CGPoint(x: 0, y: 0), font: Theme.digits(22, .semibold), color: Theme.inkPrimary)
        Ink.draw("system", at: CGPoint(x: bounds.width, y: 9), font: Theme.text(11), color: Theme.inkMuted, align: .right)
        drawSparkline(in: CGRect(x: 0, y: 34, width: bounds.width, height: 28))

        let rows: [(NSColor, String, Double?)] = [
            (Theme.blue, "SoC", sample.soc),
            (Theme.orange, "Memory", sample.memory),
            (Theme.aqua, "Other", sample.other),
        ]
        var y: CGFloat = 72
        for (color, name, value) in rows {
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: 0, y: y + 5, width: 8, height: 8)).fill()
            Ink.draw(name, at: CGPoint(x: 13, y: y), font: Theme.text(12), color: Theme.inkSecondary)
            Ink.draw(Format.watts(value), at: CGPoint(x: bounds.width, y: y), font: Theme.digits(12, .medium), color: Theme.inkPrimary, align: .right)
            y += 20
        }
        Theme.grid.setFill()
        CGRect(x: 0, y: y + 3, width: bounds.width, height: 1).fill()
        Ink.draw(footnote.label, at: CGPoint(x: 0, y: y + 8), font: Theme.text(12), color: Theme.inkMuted)
        Ink.draw(Format.watts(footnote.value), at: CGPoint(x: bounds.width, y: y + 8), font: Theme.digits(12, .medium), color: Theme.inkPrimary, align: .right)
    }

    private func drawSparkline(in area: CGRect) {
        Theme.axis.setFill()
        CGRect(x: area.minX, y: area.maxY, width: area.width, height: 1).fill()
        guard history.count > 1, let top = history.max(), top > 0 else { return }
        let scale = Scale.niceCeiling(top * 1.05)
        // Fixed spacing per sample, filling from the right, so the line scrolls like the charts.
        let step = area.width / CGFloat(Self.historyLength - 1)
        let path = NSBezierPath()
        for (index, value) in history.enumerated() {
            let point = CGPoint(
                x: area.maxX - CGFloat(history.count - 1 - index) * step,
                y: area.maxY - area.height * CGFloat(value / scale)
            )
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        Theme.inkSecondary.setStroke()
        path.stroke()
        Ink.draw(Scale.tickLabel(scale), at: CGPoint(x: area.minX, y: area.minY - 2), font: Theme.digits(9.5), color: Theme.inkMuted)
    }
}
