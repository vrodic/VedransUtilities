import AppKit

/// The instrument: a 240° arc of LED ticks, a peak-hold marker and a big readout.
final class GaugeView: DrawnView {
    var unit = "GB/s"
    var caption = "" { didSet { if caption != oldValue { needsDisplay = true } } }
    var tint: NSColor = Theme.blue { didSet { needsDisplay = true } }
    var isActive = false { didSet { needsDisplay = true } }
    /// A fixed range for bounded values such as percentages; nil auto-scales.
    var fixedScale: Double? { didSet { if let fixedScale { scaleMax = fixedScale; shownScale = fixedScale } } }
    var format: (Double) -> String = Format.number

    private var target = 0.0
    private var shown = 0.0
    private var peak = 0.0
    private var scaleMax = 10.0
    private var shownScale = 10.0
    private var link: CADisplayLink?

    private static let tickCount = 64
    private static let startAngle = 150.0
    private static let sweepAngle = 240.0

    func set(value: Double, peak: Double) {
        target = value
        self.peak = peak
        if let fixedScale {
            scaleMax = fixedScale
        } else {
            let wanted = Scale.niceCeiling(max(value, peak) * 1.05)
            // Rise right away, but only fall on a big change, so the scale doesn't hunt.
            if wanted > scaleMax || wanted < scaleMax * 0.4 { scaleMax = wanted }
        }
        wake()
        setAccessibilityLabel(peak > 0 ? "\(format(value)) \(unit), peak \(format(peak))" : "\(format(value)) \(unit)")
    }

    func reset(keepScale: Bool = false) {
        target = 0
        peak = 0
        if !keepScale { scaleMax = fixedScale ?? 10 }
        wake()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { sleep() } else { wake() }
    }

    private func wake() {
        guard link == nil, window != nil else { needsDisplay = true; return }
        let link = displayLink(target: self, selector: #selector(step))
        // Smooth enough for a needle, and light enough not to skew what it measures.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func sleep() {
        link?.invalidate()
        link = nil
    }

    @objc private func step() {
        shown += (target - shown) * 0.3
        shownScale += (scaleMax - shownScale) * 0.25
        needsDisplay = true
        // One tick's worth of arc is the most anyone can see, so stop drawing within it.
        if abs(target - shown) < scaleMax * 0.003, abs(scaleMax - shownScale) < scaleMax * 0.003 {
            shown = target
            shownScale = scaleMax
            sleep()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = min(bounds.width / 2 - 16, bounds.height * 0.54)
        let center = CGPoint(x: bounds.midX, y: radius + 10)
        let fraction = min(1, shown / shownScale)
        let lit = Int((fraction * Double(Self.tickCount)).rounded())

        let path = NSBezierPath()
        path.lineCapStyle = .round
        for tick in 0..<Self.tickCount {
            let ratio = Double(tick) / Double(Self.tickCount - 1)
            let angle = (Self.startAngle + ratio * Self.sweepAngle) * .pi / 180
            path.removeAllPoints()
            let inner = radius - 17
            path.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            path.line(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
            path.lineWidth = 3
            (tick < lit ? tint : Theme.axis).setStroke()
            path.stroke()
        }

        if peak > 0 {
            let angle = (Self.startAngle + min(1, peak / shownScale) * Self.sweepAngle) * .pi / 180
            path.removeAllPoints()
            let outer = radius + 4
            path.move(to: CGPoint(x: center.x + cos(angle) * (radius - 21), y: center.y + sin(angle) * (radius - 21)))
            path.line(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
            path.lineWidth = 2
            Theme.inkPrimary.setStroke()
            path.stroke()
        }

        let labelRadius = radius - 30
        let endpoints: [(Double, String)] = [(Self.startAngle, "0"), (Self.startAngle + Self.sweepAngle, Scale.tickLabel(scaleMax))]
        for (degrees, text) in endpoints {
            let angle = degrees * .pi / 180
            Ink.draw(
                text,
                at: CGPoint(x: center.x + cos(angle) * labelRadius, y: center.y + sin(angle) * labelRadius - 6),
                font: Theme.digits(10.5),
                color: Theme.inkMuted,
                align: .center
            )
        }

        let readout = isActive || target > 0 ? format(shown) : "—"
        let size = max(30, radius * 0.48)
        let font = Theme.digits(size, .semibold)
        Ink.draw(readout, at: CGPoint(x: center.x, y: center.y - font.pointSize * 0.78), font: font, color: Theme.inkPrimary, align: .center)
        Ink.draw(unit, at: CGPoint(x: center.x, y: center.y + font.pointSize * 0.46), font: Theme.text(13, .medium), color: Theme.inkSecondary, align: .center)
        if !caption.isEmpty {
            Ink.draw(caption, at: CGPoint(x: center.x, y: bounds.height - 18), font: Theme.text(11.5), color: Theme.inkSecondary, align: .center)
        }
    }
}
