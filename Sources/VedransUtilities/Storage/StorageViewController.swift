import AppKit

extension Theme {
    // Status colours are reserved for state, never used for a series.
    static let good = NSColor(hex: 0x0CA30C)
    static let warning = NSColor(hex: 0xFAB219)
    static let critical = NSColor(hex: 0xD03B3B)

    static func color(for status: DriveHealth.Status) -> NSColor {
        switch status {
        case .good: good
        case .warning: warning
        case .critical: critical
        }
    }

    static func symbol(for status: DriveHealth.Status) -> String {
        switch status {
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }
}

/// A status icon, always next to a label. The symbol's shape differs per status
/// too, so colour never carries the meaning alone.
private func drawStatusIcon(_ status: DriveHealth.Status, in rect: CGRect) {
    // Palette order is the inner mark, then its badge. Dark ink reads best on yellow.
    let mark = status == .warning ? Theme.page : NSColor.white
    let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .semibold)
        .applying(.init(paletteColors: [mark, Theme.color(for: status)]))
    NSImage(systemSymbolName: Theme.symbol(for: status), accessibilityDescription: status.title)?
        .withSymbolConfiguration(configuration)?
        .draw(in: rect)
}

/// The drive's name, its overall verdict, and identifying details.
private final class DriveSummaryView: DrawnView {
    var drive: DriveHealth? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let drive else { return }
        Ink.draw(drive.name, at: CGPoint(x: 0, y: 0), font: Theme.text(20, .semibold), color: Theme.inkPrimary)
        let place = drive.isInternal ? "Internal" : "External"
        let details = [place, DriveFormat.bytes(drive.capacityBytes), drive.bsdName, drive.firmware.isEmpty ? nil : "Firmware \(drive.firmware)"]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        Ink.draw(details, at: CGPoint(x: 0, y: 30), font: Theme.text(12), color: Theme.inkMuted)

        let status = drive.status
        drawStatusIcon(status, in: CGRect(x: 0, y: 64, width: 26, height: 26))
        Ink.draw(drive.hasSMART ? status.title : "Health data unavailable", at: CGPoint(x: 36, y: 64), font: Theme.text(19, .semibold), color: Theme.inkPrimary)
        let verdict: String
        if !drive.hasSMART {
            verdict = "macOS lists this drive but wouldn't return its SMART log."
        } else {
            let failing = drive.checks.filter { $0.status != .good }.map(\.title)
            verdict = failing.isEmpty ? "All health checks pass." : "Check: \(failing.joined(separator: ", "))."
        }
        Ink.draw(verdict, at: CGPoint(x: 36, y: 90), font: Theme.text(12), color: Theme.inkSecondary)
    }
}

/// One row per check, icon and label together.
private final class HealthChecksView: DrawnView {
    var checks: [DriveHealth.Check] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rowHeight: CGFloat = 35
        for (index, check) in checks.enumerated() {
            let y = CGFloat(index) * rowHeight
            guard y + rowHeight <= bounds.height + 4 else { break }
            drawStatusIcon(check.status, in: CGRect(x: 0, y: y + 3, width: 16, height: 16))
            Ink.draw(check.title, at: CGPoint(x: 26, y: y), font: Theme.text(12.5, .medium), color: Theme.inkPrimary)
            Ink.draw(check.detail, at: CGPoint(x: 26, y: y + 17), font: Theme.text(11.5), color: Theme.inkMuted)
            if index < checks.count - 1 {
                Theme.grid.setFill()
                CGRect(x: 26, y: y + rowHeight - 4, width: bounds.width - 26, height: 1).fill()
            }
        }
    }
}

final class StorageViewController: NSViewController {
    private static let refreshSeconds = 30.0

    private let picker = NSPopUpButton()
    private let gauge = GaugeView()
    private let summary = DriveSummaryView()
    private let checks = HealthChecksView()
    private let rawValues = FactListView()
    private let writtenTile = StatTile(title: "Data written")
    private let readTile = StatTile(title: "Data read")
    private let powerOnTile = StatTile(title: "Powered on")
    private let cyclesTile = StatTile(title: "Power cycles")
    private let temperatureTile = StatTile(title: "Temperature")
    private let readPanel = ReadBenchmarkPanel()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No NVMe drives with readable health data were found. USB and SATA drives don't pass SMART through to macOS without a third-party driver.")
    private var drives: [DriveHealth] = []
    private var timer: Timer?
    private let queue = DispatchQueue(label: "storage.smart", qos: .utility)

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.page.cgColor
        view = root
        buildLayout(in: root)
        gauge.unit = "% life left"
        gauge.fixedScale = 100
        gauge.format = { String(format: "%.0f", $0) }
        gauge.tint = Theme.blue
        gauge.caption = "Drive's own wear estimate"
        gauge.setAccessibilityElement(true)
        gauge.setAccessibilityRole(.levelIndicator)
        writtenTile.toolTip = "Host writes reported by the drive, in decimal units. Counted in 512,000-byte units by the NVMe spec."
        powerOnTile.toolTip = "Hours the drive has been powered, as it counts them."
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        reload()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshSeconds, repeats: true) { [weak self] _ in self?.reload() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        timer?.invalidate()
        timer = nil
    }

    private func buildLayout(in root: NSView) {
        let gaugeCard = CardView()
        gaugeCard.fill(with: gauge)
        let summaryCard = CardView(title: "Drive")
        summaryCard.fill(with: summary)
        let checksCard = CardView(title: "Health checks")
        checksCard.fill(with: checks)
        let rawCard = CardView(title: "SMART log")
        rawCard.fill(with: rawValues)
        let readCard = CardView(title: "Read speed")
        readCard.fill(with: readPanel)

        picker.target = self
        picker.action = #selector(driveChanged)
        picker.controlSize = .small
        picker.translatesAutoresizingMaskIntoConstraints = false
        summaryCard.addSubview(picker)

        let tileRow = NSStackView(views: [writtenTile, readTile, powerOnTile, cyclesTile, temperatureTile])
        tileRow.distribution = .fillEqually
        tileRow.spacing = 10

        emptyLabel.font = Theme.text(13)
        emptyLabel.textColor = Theme.inkSecondary
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true

        let note = NSTextField(wrappingLabelWithString: "Health is read from the drive's NVMe SMART log, no admin rights needed, and refreshes every 30 seconds. The read test skips files already in memory and reads uncached, so it measures the drive, not RAM.")
        note.font = Theme.text(10.5)
        note.textColor = Theme.inkMuted
        note.isSelectable = false

        for item in [gaugeCard, summaryCard, tileRow, checksCard, rawCard, readCard, note, emptyLabel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        let margin: CGFloat = 12
        NSLayoutConstraint.activate([
            gaugeCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            gaugeCard.topAnchor.constraint(equalTo: root.topAnchor, constant: margin),
            gaugeCard.widthAnchor.constraint(equalToConstant: 278),
            gaugeCard.heightAnchor.constraint(equalToConstant: 262),

            summaryCard.leadingAnchor.constraint(equalTo: gaugeCard.trailingAnchor, constant: 10),
            summaryCard.topAnchor.constraint(equalTo: gaugeCard.topAnchor),
            summaryCard.bottomAnchor.constraint(equalTo: gaugeCard.bottomAnchor),
            summaryCard.trailingAnchor.constraint(equalTo: checksCard.leadingAnchor, constant: -10),
            picker.topAnchor.constraint(equalTo: summaryCard.topAnchor, constant: 8),
            picker.trailingAnchor.constraint(equalTo: summaryCard.trailingAnchor, constant: -12),

            tileRow.leadingAnchor.constraint(equalTo: gaugeCard.leadingAnchor),
            tileRow.trailingAnchor.constraint(equalTo: checksCard.trailingAnchor),
            tileRow.topAnchor.constraint(equalTo: gaugeCard.bottomAnchor, constant: 10),
            tileRow.heightAnchor.constraint(equalToConstant: 78),

            checksCard.topAnchor.constraint(equalTo: gaugeCard.topAnchor),
            checksCard.bottomAnchor.constraint(equalTo: gaugeCard.bottomAnchor),
            checksCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            checksCard.widthAnchor.constraint(equalToConstant: 360),

            readCard.leadingAnchor.constraint(equalTo: gaugeCard.leadingAnchor),
            readCard.topAnchor.constraint(equalTo: tileRow.bottomAnchor, constant: 10),
            readCard.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -8),

            rawCard.leadingAnchor.constraint(equalTo: readCard.trailingAnchor, constant: 10),
            rawCard.topAnchor.constraint(equalTo: readCard.topAnchor),
            rawCard.bottomAnchor.constraint(equalTo: readCard.bottomAnchor),
            rawCard.trailingAnchor.constraint(equalTo: checksCard.trailingAnchor),
            rawCard.widthAnchor.constraint(equalToConstant: 280),

            note.leadingAnchor.constraint(equalTo: gaugeCard.leadingAnchor, constant: 4),
            note.trailingAnchor.constraint(equalTo: checksCard.trailingAnchor, constant: -4),
            note.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),

            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyLabel.widthAnchor.constraint(equalToConstant: 440),
        ])
        // The read test doesn't need SMART, but it measures the internal drive these cards describe.
        contentViews = [gaugeCard, summaryCard, tileRow, checksCard, rawCard, readCard]
    }

    private var contentViews: [NSView] = []

    func startReadBenchmark() {
        if !readPanel.isRunning { readPanel.toggle() }
    }

    func reload() {
        queue.async { [weak self] in
            let drives = DriveHealth.readAll()
            DispatchQueue.main.async { self?.show(drives) }
        }
    }

    private func show(_ newDrives: [DriveHealth]) {
        let selectedName = picker.titleOfSelectedItem
        drives = newDrives
        picker.removeAllItems()
        picker.addItems(withTitles: drives.map { "\($0.name) (\($0.bsdName))" })
        if let selectedName, picker.itemTitles.contains(selectedName) { picker.selectItem(withTitle: selectedName) }
        picker.isHidden = drives.count < 2
        let isEmpty = drives.isEmpty
        emptyLabel.isHidden = !isEmpty
        contentViews.forEach { $0.isHidden = isEmpty }
        driveChanged()
    }

    @objc private func driveChanged() {
        guard drives.indices.contains(picker.indexOfSelectedItem) else { return }
        let drive = drives[picker.indexOfSelectedItem]
        summary.drive = drive
        checks.checks = drive.hasSMART ? drive.checks : []
        gauge.isActive = drive.hasSMART
        gauge.set(value: drive.hasSMART ? Double(drive.lifeRemainingPercent) : 0, peak: 0)

        guard drive.hasSMART else {
            rawValues.rows = [("SMART log", "Unavailable")]
            [writtenTile, readTile, powerOnTile, cyclesTile, temperatureTile].forEach { $0.value = "—"; $0.caption = "" }
            return
        }
        writtenTile.value = DriveFormat.bytes(drive.bytesWritten)
        writtenTile.caption = "\(DriveFormat.count(drive.hostWriteCommands)) write commands"
        readTile.value = DriveFormat.bytes(drive.bytesRead)
        readTile.caption = "\(DriveFormat.count(drive.hostReadCommands)) read commands"
        powerOnTile.value = DriveFormat.hours(drive.powerOnHours)
        powerOnTile.caption = "\(DriveFormat.count(drive.powerOnHours)) hours"
        cyclesTile.value = DriveFormat.count(drive.powerCycles)
        cyclesTile.caption = "\(drive.unsafeShutdowns) unsafe shutdowns"
        temperatureTile.value = drive.temperatureCelsius.map { String(format: "%.0f °C", $0) } ?? "—"
        temperatureTile.caption = "Composite sensor"

        rawValues.rows = [
            ("Critical warning", String(format: "0x%02X", drive.criticalWarning)),
            ("Percentage used", "\(drive.percentageUsed)%"),
            ("Available spare", "\(drive.availableSpare)%"),
            ("Spare threshold", "\(drive.spareThreshold)%"),
            ("Media errors", "\(drive.mediaErrors)"),
            ("Error log entries", "\(drive.errorLogEntries)"),
            ("Unsafe shutdowns", "\(drive.unsafeShutdowns)"),
            ("Controller busy", "\(DriveFormat.count(drive.controllerBusyMinutes)) min"),
            ("Bytes per data unit", "512,000"),
        ]
    }
}
