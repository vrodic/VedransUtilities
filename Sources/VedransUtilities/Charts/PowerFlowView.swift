import AppKit

/// Where the watts come from and where they go: ribbons sized by power, with
/// particles moving along them at a speed that follows the load.
final class PowerFlowView: DrawnView {
    struct Node {
        var name: String
        var watts: Double
        var color: NSColor
    }

    var sources: [Node] = [] { didSet { needsDisplay = true } }
    var sinks: [Node] = [] { didSet { needsDisplay = true } }

    // The particles are a dashed shape layer animated by the compositor, so moving
    // them costs no drawing. A power monitor shouldn't inflate its own readings.
    private let particles = CAShapeLayer()
    private var particleDuration: CFTimeInterval = 0
    private static let dashPeriod = 15.0
    private static let referenceWatts = 120.0
    private static let minimumNodeHeight: CGFloat = 3
    private static let gap: CGFloat = 14
    private static let labelHeight: CGFloat = 34
    private static let columnWidth: CGFloat = 8
    private static let labelWidth: CGFloat = 112

    override init(frame: NSRect) {
        super.init(frame: frame)
        particles.fillColor = nil
        particles.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        particles.lineWidth = 2
        particles.lineCap = .round
        particles.lineDashPattern = [2, NSNumber(value: Self.dashPeriod - 2)]
        particles.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(particles)
    }

    override func layout() {
        super.layout()
        particles.frame = bounds
        particles.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Core Animation drops animations from layers that leave a window.
        particleDuration = 0
        if window != nil { updateParticleSpeed() }
    }

    /// Particles move faster under load, in coarse steps so the animation rarely restarts.
    private func updateParticleSpeed() {
        let watts = sinks.reduce(0) { $0 + $1.watts }
        let duration: CFTimeInterval = watts > 80 ? 0.35 : watts > 40 ? 0.55 : watts > 15 ? 0.85 : 1.3
        guard duration != particleDuration else { return }
        particleDuration = duration
        let animation = CABasicAnimation(keyPath: "lineDashPhase")
        animation.fromValue = 0
        animation.toValue = -Self.dashPeriod
        animation.duration = duration
        animation.repeatCount = .infinity
        particles.add(animation, forKey: "flow")
    }

    private struct Placed {
        var node: Node
        var rect: CGRect
    }

    private func layout(_ nodes: [Node], x: CGFloat, area: CGRect, scale: CGFloat) -> [Placed] {
        let heights = nodes.map { max(Self.minimumNodeHeight, CGFloat($0.watts) * scale) }
        // Each node needs room for its two-line label, however thin its ribbon.
        let advances = heights.map { max($0 + Self.gap, Self.labelHeight) }
        let total = advances.reduce(0, +) - (advances.last.map { $0 - (heights.last ?? 0) } ?? 0)
        var y = area.midY - total / 2
        return zip(nodes, zip(heights, advances)).map { node, size in
            defer { y += size.1 }
            return Placed(node: node, rect: CGRect(x: x, y: y, width: Self.columnWidth, height: size.0))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let visibleSources = sources.filter { $0.watts > 0.05 }
        let visibleSinks = sinks.filter { $0.watts > 0.05 }
        let particlePath = CGMutablePath()
        defer {
            particles.path = particlePath
            updateParticleSpeed()
        }
        guard !visibleSources.isEmpty || !visibleSinks.isEmpty else {
            Ink.draw("Waiting for sensors", at: CGPoint(x: bounds.midX, y: bounds.midY - 8), font: Theme.text(12), color: Theme.inkMuted, align: .center)
            return
        }
        let area = bounds.insetBy(dx: 0, dy: 6)
        let sourceTotal = visibleSources.reduce(0) { $0 + $1.watts }
        let sinkTotal = visibleSinks.reduce(0) { $0 + $1.watts }
        let usable = area.height - Self.labelHeight * CGFloat(max(visibleSources.count, visibleSinks.count, 1) - 1)
        // A fixed reference, so ribbon size means watts: idle looks small, load large.
        // Only a total beyond the reference rescales to fit.
        let scale = max(0.2, usable / CGFloat(max(sourceTotal, sinkTotal, Self.referenceWatts)))

        let leftX = Self.labelWidth
        let rightX = bounds.width - Self.labelWidth - Self.columnWidth
        let hubWidth: CGFloat = 8
        let hubX = bounds.midX - hubWidth / 2
        let left = layout(visibleSources, x: leftX, area: area, scale: scale)
        let right = layout(visibleSinks, x: rightX, area: area, scale: scale)

        // Both sides join at a central hub, at the same vertical scale.
        let hubHeight = CGFloat(max(sourceTotal, sinkTotal)) * scale
        let hub = CGRect(x: hubX, y: area.midY - hubHeight / 2, width: hubWidth, height: max(4, hubHeight))

        var hubIn = hub.minY
        for placed in left {
            ribbon(from: placed.rect, to: CGRect(x: hub.minX, y: hubIn, width: 0, height: placed.rect.height), color: placed.node.color, particles: particlePath)
            hubIn += placed.rect.height
        }
        var hubOut = hub.minY
        for placed in right {
            ribbon(from: CGRect(x: hub.maxX, y: hubOut, width: 0, height: placed.rect.height), to: placed.rect, color: placed.node.color, particles: particlePath)
            hubOut += placed.rect.height
        }

        Theme.inkPrimary.setFill()
        NSBezierPath(roundedRect: hub, xRadius: 2, yRadius: 2).fill()
        for placed in left + right {
            placed.node.color.setFill()
            NSBezierPath(roundedRect: placed.rect, xRadius: 2, yRadius: 2).fill()
        }
        for placed in left { label(placed, x: placed.rect.minX - 8, align: .right) }
        for placed in right { label(placed, x: placed.rect.maxX + 8, align: .left) }
    }

    private func label(_ placed: Placed, x: CGFloat, align: Ink.Align) {
        let y = placed.rect.midY - 15
        Ink.draw(placed.node.name, at: CGPoint(x: x, y: y), font: Theme.text(11), color: Theme.inkSecondary, align: align)
        Ink.draw(Format.watts(placed.node.watts), at: CGPoint(x: x, y: y + 14), font: Theme.digits(12, .semibold), color: Theme.inkPrimary, align: align)
    }

    private func ribbon(from start: CGRect, to end: CGRect, color: NSColor, particles: CGMutablePath) {
        let x0 = start.maxX, x1 = end.minX
        let midX = (x0 + x1) / 2
        let shape = NSBezierPath()
        shape.move(to: CGPoint(x: x0, y: start.minY))
        shape.curve(to: CGPoint(x: x1, y: end.minY), controlPoint1: CGPoint(x: midX, y: start.minY), controlPoint2: CGPoint(x: midX, y: end.minY))
        shape.line(to: CGPoint(x: x1, y: end.maxY))
        shape.curve(to: CGPoint(x: x0, y: start.maxY), controlPoint1: CGPoint(x: midX, y: end.maxY), controlPoint2: CGPoint(x: midX, y: start.maxY))
        shape.close()
        color.withAlphaComponent(0.34).setFill()
        shape.fill()

        particles.move(to: CGPoint(x: x0, y: start.midY))
        particles.addCurve(
            to: CGPoint(x: x1, y: end.midY),
            control1: CGPoint(x: midX, y: start.midY),
            control2: CGPoint(x: midX, y: end.midY)
        )
    }
}
