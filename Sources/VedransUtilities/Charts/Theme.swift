import AppKit

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// The app is an always-dark instrument panel. Series colours are in fixed slots,
/// so an operation or power rail keeps its colour wherever it appears.
enum Theme {
    static let page = NSColor(hex: 0x0D0D0D)
    static let surface = NSColor(hex: 0x1A1A19)
    static let raised = NSColor(hex: 0x242423)
    static let border = NSColor(white: 1, alpha: 0.10)
    static let grid = NSColor(hex: 0x2C2C2A)
    static let axis = NSColor(hex: 0x383835)
    static let inkPrimary = NSColor(hex: 0xF0EFEC)
    static let inkSecondary = NSColor(hex: 0xC3C2B7)
    static let inkMuted = NSColor(hex: 0x898781)

    static let blue = NSColor(hex: 0x3987E5)
    static let orange = NSColor(hex: 0xD95926)
    static let aqua = NSColor(hex: 0x199E70)
    static let yellow = NSColor(hex: 0xC98500)
    static let magenta = NSColor(hex: 0xD55181)
    static let violet = NSColor(hex: 0x9085E9)

    /// Single-hue magnitude ramp, dim to bright on a dark surface.
    static let ramp: [NSColor] = [0x104281, 0x184F95, 0x1C5CAB, 0x256ABF, 0x2A78D6, 0x3987E5, 0x5598E7, 0x6DA7EC, 0x86B6EF, 0x9EC5F4, 0xB7D3F6, 0xCDE2FB]
        .map { NSColor(hex: UInt32($0)) }

    static func rampColor(_ fraction: Double) -> NSColor {
        let clamped = min(1, max(0, fraction))
        return ramp[min(ramp.count - 1, Int(clamped * Double(ramp.count)))]
    }

    static func text(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    /// Fixed-width digits, for values that update live or align on an axis.
    static func digits(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

extension MemoryOperation {
    var color: NSColor {
        switch self {
        case .read: Theme.blue
        case .write: Theme.orange
        case .copy: Theme.aqua
        case .triad: Theme.yellow
        case .random: Theme.magenta
        }
    }
}

/// Text placement for flipped custom views.
enum Ink {
    enum Align { case left, center, right }

    @discardableResult
    static func draw(_ text: String, at point: CGPoint, font: NSFont, color: NSColor, align: Align = .left) -> CGSize {
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = attributed.size()
        var origin = point
        switch align {
        case .left: break
        case .center: origin.x -= size.width / 2
        case .right: origin.x -= size.width
        }
        attributed.draw(at: origin)
        return size
    }

    static func width(_ text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// A value box near the pointer, kept inside `bounds`.
    static func tooltip(lines: [(dot: NSColor?, text: String)], near point: CGPoint, in bounds: CGRect) {
        let font = Theme.digits(11)
        let lineHeight: CGFloat = 16
        let dotSpace: CGFloat = lines.contains { $0.dot != nil } ? 13 : 0
        let width = (lines.map { Ink.width($0.text, font: font) }.max() ?? 0) + dotSpace + 18
        let height = CGFloat(lines.count) * lineHeight + 10
        var x = point.x + 14
        if x + width > bounds.maxX - 4 { x = point.x - width - 14 }
        x = max(bounds.minX + 4, x)
        let y = min(max(bounds.minY + 4, point.y - height / 2), bounds.maxY - height - 4)
        let box = CGRect(x: x, y: y, width: width, height: height)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor(hex: 0x2C2C2A).setFill()
        path.fill()
        Theme.border.setStroke()
        path.lineWidth = 1
        path.stroke()
        for (index, line) in lines.enumerated() {
            let lineY = y + 5 + CGFloat(index) * lineHeight
            if let dot = line.dot {
                dot.setFill()
                NSBezierPath(ovalIn: CGRect(x: x + 9, y: lineY + 4, width: 8, height: 8)).fill()
            }
            Ink.draw(line.text, at: CGPoint(x: x + 9 + dotSpace, y: lineY), font: font, color: Theme.inkPrimary)
        }
    }
}

enum Scale {
    /// The next round number at or above `value`, for axes and gauge ranges.
    static func niceCeiling(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        for step in [1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10] where step * magnitude >= value * 0.9999 {
            return step * magnitude
        }
        return 10 * magnitude
    }

    /// Round tick spacing giving roughly `count` intervals.
    static func tickStep(max: Double, count: Int) -> Double {
        guard max > 0 else { return 1 }
        let raw = max / Double(count)
        let magnitude = pow(10, floor(log10(raw)))
        for step in [1.0, 2, 2.5, 5, 10] where step * magnitude >= raw * 0.9999 {
            return step * magnitude
        }
        return 10 * magnitude
    }

    static func tickLabel(_ value: Double) -> String {
        if value == 0 { return "0" }
        if value >= 10 || value == value.rounded() { return String(format: "%.0f", value) }
        return String(format: value >= 1 ? "%.1f" : "%.2f", value)
    }
}

/// Base for custom-drawn views: flipped, layer-backed, redrawn only on request.
class DrawnView: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// A DrawnView with a hover position, shared by the charts' crosshairs and tooltips.
class HoverableView: DrawnView {
    private(set) var hoverPoint: CGPoint?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        needsDisplay = true
    }
}

/// A rounded panel with an optional small title.
final class CardView: NSView {
    let content = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var contentTop: NSLayoutConstraint!

    var title: String {
        get { titleLabel.stringValue }
        set {
            titleLabel.stringValue = newValue
            contentTop.constant = newValue.isEmpty ? 14 : 36
        }
    }

    override var isFlipped: Bool { true }

    init(title: String = "", inset: CGFloat = 14) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = Theme.border.cgColor

        titleLabel.font = Theme.text(12, .semibold)
        titleLabel.textColor = Theme.inkSecondary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        contentTop = content.topAnchor.constraint(equalTo: topAnchor, constant: 14)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            contentTop,
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func fill(with view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }
}

/// A headline number with a caption and optional identity dot and sparkline.
final class StatTile: DrawnView {
    var title: String { didSet { needsDisplay = true } }
    var value = "—" { didSet { if value != oldValue { refresh() } } }
    var caption = "" { didSet { if caption != oldValue { refresh() } } }
    var dot: NSColor?
    var sparkline: [Double] = [] { didSet { needsDisplay = true } }
    var sparkColor: NSColor = Theme.blue

    init(title: String, dot: NSColor? = nil) {
        self.title = title
        self.dot = dot
        super.init(frame: .zero)
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = Theme.border.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    private func refresh() {
        needsDisplay = true
        setAccessibilityLabel("\(title): \(value). \(caption)")
    }

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 12
        if let dot {
            dot.setFill()
            NSBezierPath(ovalIn: CGRect(x: x, y: 13.5, width: 8, height: 8)).fill()
            x += 13
        }
        Ink.draw(title, at: CGPoint(x: x, y: 9), font: Theme.text(11.5, .medium), color: Theme.inkSecondary)
        Ink.draw(value, at: CGPoint(x: 12, y: 26), font: Theme.digits(22, .semibold), color: Theme.inkPrimary)
        Ink.draw(caption, at: CGPoint(x: 12, y: 55), font: Theme.digits(10.5), color: Theme.inkMuted)

        guard sparkline.count > 1, let top = sparkline.max() else { return }
        let area = CGRect(x: bounds.width * 0.5, y: 28, width: bounds.width * 0.5 - 12, height: 24)
        let maxValue = max(top, 0.001)
        let path = NSBezierPath()
        for (index, sample) in sparkline.enumerated() {
            let point = CGPoint(
                x: area.minX + area.width * CGFloat(index) / CGFloat(sparkline.count - 1),
                y: area.maxY - area.height * CGFloat(min(1, max(0, sample / maxValue)))
            )
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        sparkColor.setStroke()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.stroke()
    }
}
