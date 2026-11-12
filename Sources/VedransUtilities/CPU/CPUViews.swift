import AppKit

extension CPUInfo.CoreKind {
    var color: NSColor { self == .performance ? Theme.blue : Theme.aqua }
}

/// One bar per core, grouped by cluster: load as the fill, clock speed above.
final class CoreGridView: DrawnView {
    var cores: [CPUInfo.Core] = [] { didSet { needsDisplay = true } }
    var loads: [CoreLoad] = [] { didSet { if loads != oldValue { needsDisplay = true } } }

    private static let groupGap: CGFloat = 20

    override func draw(_ dirtyRect: NSRect) {
        guard !cores.isEmpty else { return }
        var clusters: [[Int]] = []
        for index in cores.indices {
            if let last = clusters.last, cores[last[0]].cluster == cores[index].cluster {
                clusters[clusters.count - 1].append(index)
            } else {
                clusters.append([index])
            }
        }
        let gaps = Self.groupGap * CGFloat(clusters.count - 1)
        let cell = min(48, (bounds.width - gaps) / CGFloat(cores.count))
        let barTop: CGFloat = 20
        let barBottom = bounds.height - 36
        let showsClock = cell >= 26
        var x: CGFloat = 0

        for cluster in clusters {
            let startX = x
            let kind = cores[cluster[0]].kind
            for index in cluster {
                let load = loads.indices.contains(index) ? loads[index] : CoreLoad(active: 0)
                let bar = CGRect(x: x + 3, y: barTop, width: max(2, cell - 6), height: max(1, barBottom - barTop))
                let radius = min(5, bar.width / 2)
                Theme.raised.setFill()
                NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()

                let fraction = CGFloat(min(1, max(0, load.active)))
                if fraction > 0.004 {
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).addClip()
                    kind.color.setFill()
                    CGRect(x: bar.minX, y: bar.maxY - bar.height * fraction, width: bar.width, height: bar.height * fraction).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                if showsClock {
                    let clock = load.megahertz.map { String(format: cell >= 34 ? "%.2f" : "%.1f", $0 / 1000) } ?? "·"
                    Ink.draw(clock, at: CGPoint(x: x + cell / 2, y: 2), font: Theme.digits(10.5, .medium),
                             color: load.megahertz == nil ? Theme.inkMuted : Theme.inkPrimary, align: .center)
                }
                Ink.draw("\(cores[index].id)", at: CGPoint(x: x + cell / 2, y: barBottom + 4), font: Theme.digits(10), color: Theme.inkMuted, align: .center)
                x += cell
            }
            let width = x - startX
            let caption = width >= 84 ? kind.title : kind.letter
            Ink.draw(caption, at: CGPoint(x: startX + width / 2, y: barBottom + 20), font: Theme.text(11, .medium), color: Theme.inkSecondary, align: .center)
            x += Self.groupGap
        }
    }
}

/// Feature names as wrapped text. Absent ones are dimmed and come last.
final class FeatureListView: DrawnView {
    var features: [CPUInfo.Feature] = [] { didSet { needsDisplay = true } }

    static let absentColor = NSColor(hex: 0x5F5E59)

    override func draw(_ dirtyRect: NSRect) {
        let supported = features.filter(\.isSupported).count
        Ink.draw("\(supported) present, \(features.count - supported) absent and dimmed", at: .zero, font: Theme.text(11), color: Theme.inkMuted)
        let font = Theme.text(10.5)
        let lineHeight: CGFloat = 15
        var x: CGFloat = 0
        var y: CGFloat = 20
        for feature in features {
            let width = Ink.width(feature.name, font: font)
            if x > 0, x + width > bounds.width {
                x = 0
                y += lineHeight
            }
            guard y + lineHeight <= bounds.height + 2 else { break }
            Ink.draw(feature.name, at: CGPoint(x: x, y: y), font: font, color: feature.isSupported ? Theme.inkSecondary : Self.absentColor)
            x += width + 9
        }
    }
}

/// The results table: a row per test, a column per run mode, then how well the
/// test scaled and what each mode cost in power.
final class CPUResultsView: DrawnView {
    var modes: [CPURunMode] = [] { didSet { needsDisplay = true } }
    var modeTitles: [CPURunMode: String] = [:] { didSet { needsDisplay = true } }
    var results: [CPUBenchCell: Double] = [:] { didSet { refresh() } }
    /// The test running now and its reading so far.
    var active: (cell: CPUBenchCell, rate: Double?)? { didSet { needsDisplay = true } }
    /// Mean power this app's CPU work drew during each mode, in watts.
    var power: [CPURunMode: Double] = [:] { didSet { needsDisplay = true } }

    private static let headerHeight: CGFloat = 26
    private static let rowHeight: CGFloat = 40

    /// All cores against one P-core.
    func scaling(_ workload: CPUWorkload) -> Double? {
        guard let all = results[CPUBenchCell(workload: workload, mode: .allCores)],
              let one = results[CPUBenchCell(workload: workload, mode: .performanceCore)], one > 0 else { return nil }
        return all / one
    }

    private func refresh() {
        needsDisplay = true
        let lines = CPUWorkload.allCases.map { workload in
            let values = modes.compactMap { mode in
                results[CPUBenchCell(workload: workload, mode: mode)].map { "\(modeTitles[mode] ?? ""): \(Format.number($0 / workload.unitScale)) \(workload.unit)" }
            }
            return values.isEmpty ? nil : "\(workload.name). \(values.joined(separator: ", "))"
        }
        setAccessibilityLabel(lines.compactMap { $0 }.joined(separator: ". "))
    }

    override func draw(_ dirtyRect: NSRect) {
        let nameWidth = min(250, bounds.width * 0.34)
        let columnWidth = (bounds.width - nameWidth) / CGFloat(modes.count + 1)
        func rightEdge(_ column: Int) -> CGFloat { nameWidth + columnWidth * CGFloat(column + 1) - 10 }

        let headerFont = Theme.text(11.5, .medium)
        Ink.draw("Test", at: CGPoint(x: 0, y: 4), font: headerFont, color: Theme.inkMuted)
        for (column, mode) in modes.enumerated() {
            Ink.draw(modeTitles[mode] ?? "", at: CGPoint(x: rightEdge(column), y: 4), font: headerFont, color: Theme.inkMuted, align: .right)
        }
        Ink.draw("Scaling", at: CGPoint(x: rightEdge(modes.count), y: 4), font: headerFont, color: Theme.inkMuted, align: .right)

        let valueFont = Theme.digits(13, .medium)
        let unitFont = Theme.text(10.5)
        var y = Self.headerHeight
        for workload in CPUWorkload.allCases {
            Theme.grid.setFill()
            CGRect(x: 0, y: y - 1, width: bounds.width, height: 1).fill()
            Ink.draw(workload.name, at: CGPoint(x: 0, y: y + 5), font: Theme.text(12.5, .medium), color: Theme.inkPrimary)
            Ink.draw(workload.detail, at: CGPoint(x: 0, y: y + 21), font: Theme.text(11), color: Theme.inkMuted)

            let unitWidth = Ink.width(workload.unit, font: unitFont)
            for (column, mode) in modes.enumerated() {
                let cell = CPUBenchCell(workload: workload, mode: mode)
                let isActive = active?.cell == cell
                if isActive {
                    Theme.raised.setFill()
                    let box = CGRect(x: nameWidth + columnWidth * CGFloat(column) + 4, y: y + 4, width: columnWidth - 8, height: Self.rowHeight - 9)
                    NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
                }
                let value = isActive ? active?.rate : results[cell]
                let edge = rightEdge(column)
                guard let value else {
                    Ink.draw(isActive ? "…" : "—", at: CGPoint(x: edge, y: y + 11), font: valueFont, color: Theme.inkMuted, align: .right)
                    continue
                }
                Ink.draw(workload.unit, at: CGPoint(x: edge, y: y + 14), font: unitFont, color: Theme.inkMuted, align: .right)
                Ink.draw(Format.number(value / workload.unitScale), at: CGPoint(x: edge - unitWidth - 5, y: y + 11), font: valueFont,
                         color: isActive ? Theme.blue : Theme.inkPrimary, align: .right)
            }
            let scale = scaling(workload).map { String(format: "%.1f×", $0) } ?? "—"
            Ink.draw(scale, at: CGPoint(x: rightEdge(modes.count), y: y + 11), font: valueFont, color: scale == "—" ? Theme.inkMuted : Theme.inkSecondary, align: .right)
            y += Self.rowHeight
        }

        Theme.axis.setFill()
        CGRect(x: 0, y: y - 1, width: bounds.width, height: 1).fill()
        Ink.draw("Power", at: CGPoint(x: 0, y: y + 5), font: Theme.text(12.5, .medium), color: Theme.inkPrimary)
        Ink.draw("This app's CPU, mean over the column", at: CGPoint(x: 0, y: y + 21), font: Theme.text(11), color: Theme.inkMuted)
        for (column, mode) in modes.enumerated() {
            Ink.draw(Format.watts(power[mode]), at: CGPoint(x: rightEdge(column), y: y + 11), font: valueFont,
                     color: power[mode] == nil ? Theme.inkMuted : Theme.inkPrimary, align: .right)
        }
    }
}
