import AppKit

/// Rows of label and value, for facts that have no shape worth charting.
final class FactListView: DrawnView {
    var rows: [(String, String)] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let rowHeight: CGFloat = 22
        for (index, row) in rows.enumerated() {
            let y = CGFloat(index) * rowHeight
            guard y + rowHeight <= bounds.height + 2 else { break }
            Ink.draw(row.0, at: CGPoint(x: 0, y: y + 3), font: Theme.text(12), color: Theme.inkMuted)
            Ink.draw(row.1, at: CGPoint(x: bounds.width, y: y + 3), font: Theme.digits(12, .medium), color: Theme.inkPrimary, align: .right)
        }
    }
}

final class PowerViewController: NSViewController {
    private let monitor = PowerMonitor.shared

    private let gauge = GaugeView()
    private let chart = TimeSeriesChartView()
    private let flow = PowerFlowView()
    private let socTile = StatTile(title: "SoC rail", dot: Theme.blue)
    private let memoryTile = StatTile(title: "Memory rail", dot: Theme.orange)
    private let otherTile = StatTile(title: "Everything else", dot: Theme.aqua)
    private let gpuTile = StatTile(title: "GPU, within SoC", dot: Theme.violet)
    private let appTile = StatTile(title: "This app's CPU")
    private let batteryList = FactListView()
    private let sessionList = FactListView()
    private let batteryCard = CardView(title: "Battery")

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.page.cgColor
        view = root
        buildLayout(in: root)

        chart.series = [
            .init(name: "SoC", color: Theme.blue),
            .init(name: "Memory", color: Theme.orange),
            .init(name: "Other", color: Theme.aqua),
        ]
        chart.isStacked = true
        chart.unit = "W"
        chart.windowSeconds = 300
        chart.gapSeconds = 3
        chart.emptyMessage = "Waiting for sensors"
        gauge.unit = "W"
        gauge.tint = Theme.inkSecondary
        gauge.caption = "System total"
        socTile.sparkColor = Theme.blue
        memoryTile.sparkColor = Theme.orange
        otherTile.sparkColor = Theme.aqua
        gpuTile.sparkColor = Theme.violet
        socTile.toolTip = "SMC key PSVR. Follows both CPU and GPU load."
        memoryTile.toolTip = "SMC key PMVC. Stays flat on cache-only work and rises with DRAM traffic."
        otherTile.toolTip = "System total minus the SoC and memory rails: display, storage, radios and so on."
        gpuTile.toolTip = "IOReport GPU Energy. A separate reading, already included in the SoC rail. Reads well below the rail's rise under GPU load, so treat it as a lower bound."
        appTile.toolTip = "CPU energy macOS attributes to this process, from rusage. During a benchmark, that's the workers."
        gauge.setAccessibilityElement(true)
        gauge.setAccessibilityRole(.levelIndicator)
        appTile.sparkColor = Theme.inkSecondary

        for sample in monitor.history { appendToChart(sample) }
        NotificationCenter.default.addObserver(forName: .powerSample, object: nil, queue: .main) { [weak self] note in
            if let sample = note.object as? PowerSample { self?.handle(sample) }
        }
        monitor.onBattery = { [weak self] status in self?.updateBattery(status) }
        updateBattery(monitor.battery)
    }

    private func buildLayout(in root: NSView) {
        let gaugeCard = CardView()
        gaugeCard.fill(with: gauge)
        let chartCard = CardView(title: "Power by rail, last 5 minutes")
        chartCard.fill(with: chart)
        let flowCard = CardView(title: "Power flow")
        flowCard.fill(with: flow)
        batteryCard.fill(with: batteryList)
        let sessionCard = CardView(title: "Since launch")
        sessionCard.fill(with: sessionList)

        let tileRow = NSStackView(views: [socTile, memoryTile, otherTile, gpuTile, appTile])
        tileRow.distribution = .fillEqually
        tileRow.spacing = 10

        let note = NSTextField(wrappingLabelWithString: "Readings need no admin rights. macOS doesn't document these sensors, so rail names reflect how each one responded to CPU, memory and GPU tests on this Mac. Hover a tile for its source.")
        note.font = Theme.text(10.5)
        note.textColor = Theme.inkMuted
        note.isSelectable = false

        for item in [gaugeCard, chartCard, flowCard, batteryCard, sessionCard, tileRow, note] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        let margin: CGFloat = 12
        NSLayoutConstraint.activate([
            gaugeCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            gaugeCard.topAnchor.constraint(equalTo: root.topAnchor, constant: margin),
            gaugeCard.widthAnchor.constraint(equalToConstant: 278),
            gaugeCard.heightAnchor.constraint(equalToConstant: 262),

            chartCard.leadingAnchor.constraint(equalTo: gaugeCard.trailingAnchor, constant: 10),
            chartCard.topAnchor.constraint(equalTo: gaugeCard.topAnchor),
            chartCard.bottomAnchor.constraint(equalTo: gaugeCard.bottomAnchor),
            chartCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),

            tileRow.leadingAnchor.constraint(equalTo: gaugeCard.leadingAnchor),
            tileRow.trailingAnchor.constraint(equalTo: chartCard.trailingAnchor),
            tileRow.topAnchor.constraint(equalTo: gaugeCard.bottomAnchor, constant: 10),
            tileRow.heightAnchor.constraint(equalToConstant: 78),

            flowCard.leadingAnchor.constraint(equalTo: gaugeCard.leadingAnchor),
            flowCard.topAnchor.constraint(equalTo: tileRow.bottomAnchor, constant: 10),
            flowCard.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -8),

            batteryCard.leadingAnchor.constraint(equalTo: flowCard.trailingAnchor, constant: 10),
            batteryCard.topAnchor.constraint(equalTo: flowCard.topAnchor),
            batteryCard.bottomAnchor.constraint(equalTo: flowCard.bottomAnchor),
            batteryCard.widthAnchor.constraint(equalToConstant: 252),

            sessionCard.leadingAnchor.constraint(equalTo: batteryCard.trailingAnchor, constant: 10),
            sessionCard.topAnchor.constraint(equalTo: flowCard.topAnchor),
            sessionCard.bottomAnchor.constraint(equalTo: flowCard.bottomAnchor),
            sessionCard.trailingAnchor.constraint(equalTo: chartCard.trailingAnchor),
            sessionCard.widthAnchor.constraint(equalToConstant: 232),

            note.leadingAnchor.constraint(equalTo: gaugeCard.leadingAnchor, constant: 4),
            note.trailingAnchor.constraint(equalTo: chartCard.trailingAnchor, constant: -4),
            note.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
        ])
    }

    private func appendToChart(_ sample: PowerSample) {
        guard sample.system != nil else { return }
        chart.append(time: sample.time, values: [sample.soc ?? 0, sample.memory ?? 0, sample.other ?? 0])
    }

    private func spark(_ path: KeyPath<PowerSample, Double?>) -> [Double] {
        monitor.history.suffix(120).map { $0[keyPath: path] ?? 0 }
    }

    private func handle(_ sample: PowerSample) {
        appendToChart(sample)
        guard isViewLoaded, view.window != nil else { return }
        gauge.isActive = sample.system != nil
        gauge.set(value: sample.system ?? 0, peak: monitor.systemStats.peak)

        update(socTile, sample.soc, monitor.socStats, \.soc)
        update(memoryTile, sample.memory, monitor.memoryStats, \.memory)
        update(otherTile, sample.other, monitor.otherStats, \.other)
        update(gpuTile, sample.gpu, monitor.gpuStats, \.gpu)
        appTile.value = Format.watts(sample.thisAppCPU)
        appTile.caption = "Workers and interface"
        appTile.sparkline = spark(\.thisAppCPU)

        var sources: [PowerFlowView.Node] = []
        var sinks: [PowerFlowView.Node] = [
            .init(name: "SoC", watts: sample.soc ?? 0, color: Theme.blue),
            .init(name: "Memory", watts: sample.memory ?? 0, color: Theme.orange),
            .init(name: "Other", watts: sample.other ?? 0, color: Theme.aqua),
        ]
        let batteryFlow = monitor.battery?.flowWatts ?? 0
        if monitor.battery?.isExternalPowerConnected ?? true, let adapter = sample.adapter {
            sources.append(.init(name: "Adapter", watts: adapter, color: Theme.inkMuted))
        }
        if batteryFlow < 0 {
            sources.append(.init(name: "Battery", watts: -batteryFlow, color: Theme.yellow))
        } else if batteryFlow > 0 {
            sinks.append(.init(name: "Charging", watts: batteryFlow, color: Theme.yellow))
        }
        flow.sources = sources
        flow.sinks = sinks

        sessionList.rows = [
            ("Energy used", String(format: "%.2f Wh", monitor.energyWattHours)),
            ("Average", Format.watts(monitor.systemStats.mean)),
            ("Peak", Format.watts(monitor.systemStats.peak)),
            ("Adapter input", Format.watts(sample.adapter)),
            ("Peak SoC", Format.watts(monitor.socStats.peak)),
            ("Peak memory", Format.watts(monitor.memoryStats.peak)),
        ]
    }

    private func update(_ tile: StatTile, _ value: Double?, _ stats: PowerChannelStats, _ path: KeyPath<PowerSample, Double?>) {
        tile.value = Format.watts(value)
        tile.caption = "Peak \(Format.watts(stats.peak)), avg \(Format.watts(stats.mean))"
        tile.sparkline = spark(path)
    }

    private func updateBattery(_ status: BatteryStatus?) {
        guard let status else {
            batteryList.rows = [("Battery", "None")]
            return
        }
        var rows: [(String, String)] = [("Charge", "\(status.chargePercent)%")]
        let state: String
        if status.isFullyCharged {
            state = "Fully charged"
        } else if status.isCharging {
            state = "Charging"
        } else if status.isExternalPowerConnected {
            state = "On adapter, not charging"
        } else {
            state = "On battery"
        }
        rows.append(("State", state))
        if let minutes = status.minutesRemaining {
            rows.append((status.isCharging ? "Until full" : "Remaining", Format.duration(minutes: minutes)))
        }
        if let health = status.healthPercent { rows.append(("Health", "\(health)%")) }
        rows.append(("Cycles", "\(status.cycleCount)"))
        rows.append(("Battery flow", String(format: "%+.1f W", status.flowWatts)))
        rows.append(("Pack voltage", String(format: "%.2f V", status.voltage)))
        if let temperature = status.temperatureCelsius { rows.append(("Temperature", String(format: "%.1f °C", temperature))) }
        if let watts = status.adapterRatedWatts { rows.append(("Adapter rating", "\(watts) W")) }
        batteryList.rows = rows
    }
}
