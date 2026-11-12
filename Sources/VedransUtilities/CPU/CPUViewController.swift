import AppKit

final class CPUViewController: NSViewController {
    private let info = CPUInfo.current
    private let monitor = CPULoadMonitor()
    /// Shortened by tests.
    var timing = CPUSuiteRunner.Timing()

    private let chipName = NSTextField(labelWithString: "")
    private let chipDetail = NSTextField(labelWithString: "")
    private let facts = FactListView()
    private let coresCard = CardView(title: "Cores, live")
    private let coreGrid = CoreGridView()
    private let powerSummary = PowerSummaryView()
    private let features = FeatureListView()
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    let results = CPUResultsView()

    private var runner: CPUSuiteRunner?
    private var measured = 0
    private var thermalState = ProcessInfo.processInfo.thermalState
    private var powerMode: CPURunMode?
    /// The sample that straddles a change of mode belongs to neither.
    private var skipPowerSample = false
    private var powerTotals: [CPURunMode: (sum: Double, count: Int)] = [:]

    var isRunning: Bool { runner != nil }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.page.cgColor
        view = root
        buildLayout(in: root)

        chipName.stringValue = info.chipName
        chipDetail.stringValue = [info.modelIdentifier, "\(info.cores.count) cores", "\(Format.bytes(info.memoryBytes)) memory"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        coreGrid.cores = info.cores
        features.features = info.features
        results.modes = CPURunMode.available(info)
        results.modeTitles = Dictionary(uniqueKeysWithValues: CPURunMode.allCases.map { ($0, $0.title(info)) })
        showFacts()
        showIdle()

        monitor.onSample = { [weak self] loads in self?.show(loads) }
        NotificationCenter.default.addObserver(forName: .powerSample, object: nil, queue: .main) { [weak self] note in
            guard let self, let sample = note.object as? PowerSample else { return }
            self.powerSummary.update(sample)
            self.powerSummary.footnote = ("This app's CPU", sample.thisAppCPU)
            self.record(sample)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        monitor.start()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        // A run keeps going in the background, but nobody is watching the bars.
        monitor.stop()
    }

    // MARK: Layout

    private func buildLayout(in root: NSView) {
        let chipCard = CardView()
        chipName.font = Theme.text(20, .semibold)
        chipName.textColor = Theme.inkPrimary
        chipDetail.font = Theme.text(12)
        chipDetail.textColor = Theme.inkMuted
        for item in [chipName, chipDetail, facts] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            chipCard.content.addSubview(item)
        }

        coresCard.fill(with: coreGrid)
        coresCard.toolTip = "Each bar is one core: how busy it was over the last half second, with its clock speed in GHz above while it runs."
        let powerCard = CardView(title: "Power")
        powerCard.fill(with: powerSummary)
        powerCard.toolTip = "The same readings as the Power tab, so you can see what a test costs while it runs."
        let featuresCard = CardView(title: "Instruction set")
        featuresCard.fill(with: features)
        featuresCard.toolTip = "Every optional ARM feature macOS reports for this processor, from sysctl hw.optional.arm."
        let benchCard = CardView(title: "Benchmark")
        let bench = buildBenchmarkPanel()
        benchCard.fill(with: bench)

        for item in [chipCard, featuresCard, coresCard, powerCard, benchCard] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }
        let margin: CGFloat = 12
        NSLayoutConstraint.activate([
            chipCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            chipCard.topAnchor.constraint(equalTo: root.topAnchor, constant: margin),
            chipCard.widthAnchor.constraint(equalToConstant: 336),
            chipName.leadingAnchor.constraint(equalTo: chipCard.content.leadingAnchor),
            chipName.topAnchor.constraint(equalTo: chipCard.content.topAnchor),
            chipDetail.leadingAnchor.constraint(equalTo: chipName.leadingAnchor),
            chipDetail.topAnchor.constraint(equalTo: chipName.bottomAnchor, constant: 3),
            facts.leadingAnchor.constraint(equalTo: chipCard.content.leadingAnchor),
            facts.trailingAnchor.constraint(equalTo: chipCard.content.trailingAnchor),
            facts.topAnchor.constraint(equalTo: chipDetail.bottomAnchor, constant: 12),
            facts.bottomAnchor.constraint(equalTo: chipCard.content.bottomAnchor),
            facts.heightAnchor.constraint(equalToConstant: 22 * 12),

            featuresCard.leadingAnchor.constraint(equalTo: chipCard.leadingAnchor),
            featuresCard.trailingAnchor.constraint(equalTo: chipCard.trailingAnchor),
            featuresCard.topAnchor.constraint(equalTo: chipCard.bottomAnchor, constant: 10),
            featuresCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -margin),

            coresCard.leadingAnchor.constraint(equalTo: chipCard.trailingAnchor, constant: 10),
            coresCard.topAnchor.constraint(equalTo: chipCard.topAnchor),
            coresCard.heightAnchor.constraint(equalToConstant: 262),
            coresCard.trailingAnchor.constraint(equalTo: powerCard.leadingAnchor, constant: -10),

            powerCard.topAnchor.constraint(equalTo: coresCard.topAnchor),
            powerCard.bottomAnchor.constraint(equalTo: coresCard.bottomAnchor),
            powerCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            powerCard.widthAnchor.constraint(equalToConstant: 212),

            benchCard.leadingAnchor.constraint(equalTo: coresCard.leadingAnchor),
            benchCard.trailingAnchor.constraint(equalTo: powerCard.trailingAnchor),
            benchCard.topAnchor.constraint(equalTo: coresCard.bottomAnchor, constant: 10),
            benchCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -margin),
        ])
        coreGrid.setAccessibilityElement(true)
        coreGrid.setAccessibilityRole(.group)
        results.setAccessibilityElement(true)
        results.setAccessibilityRole(.staticText)
    }

    private func buildBenchmarkPanel() -> NSView {
        let panel = NSView()
        startButton.target = self
        startButton.action = #selector(toggleBenchmark)
        startButton.bezelStyle = .push
        startButton.bezelColor = Theme.blue
        startButton.toolTip = "Runs each test on one P-core, one E-core, then every core at once."
        status.font = Theme.text(12)
        status.textColor = Theme.inkSecondary
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.controlSize = .small

        let note = NSTextField(wrappingLabelWithString: "Every test fits in L1, so it measures the cores and not memory. macOS can't pin threads: the E-core column is a background-priority thread, which macOS keeps on the E-cores and may clock below their maximum. Scaling is all cores divided by one P-core.")
        note.font = Theme.text(10.5)
        note.textColor = Theme.inkMuted
        note.isSelectable = false

        let toolbar = NSStackView(views: [startButton, status, progress])
        toolbar.orientation = .horizontal
        toolbar.spacing = 12
        for item in [toolbar, results, note] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(item)
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: panel.topAnchor),
            progress.widthAnchor.constraint(equalToConstant: 160),

            results.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            results.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            results.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 12),
            results.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -8),

            note.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            note.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        return panel
    }

    // MARK: Information

    private func showFacts() {
        func gigahertz(_ megahertz: Double) -> String { String(format: "%.2f", megahertz / 1000) }
        var rows: [(String, String)] = []
        for kind in [CPUInfo.CoreKind.performance, .efficiency] {
            let count = info.cores(kind).count
            guard count > 0 else { continue }
            let parts = [info.design(kind).map { "\(count) × \($0)" } ?? "\(count)", info.maxMegahertz(kind).map { "\(gigahertz($0)) GHz" }]
            rows.append(("\(kind.title) cores", parts.compactMap { $0 }.joined(separator: " · ")))
        }
        rows.append(("Clusters", info.clusterSummary))
        for kind in [CPUInfo.CoreKind.performance, .efficiency] {
            guard let caches = info.caches[kind] else { continue }
            rows.append(("\(kind.letter)-core L1", "\(Format.bytes(caches.l1Instruction)) code · \(Format.bytes(caches.l1Data)) data"))
            rows.append(("\(kind.letter)-core L2", "\(Format.bytes(caches.l2)) per \(caches.coresPerL2) cores"))
        }
        let ranges = [CPUInfo.CoreKind.performance, .efficiency].compactMap { kind -> String? in
            guard let states = info.states[kind], let low = states.map(\.megahertz).min(), let high = states.map(\.megahertz).max() else { return nil }
            return "\(kind.letter) \(gigahertz(low))–\(gigahertz(high))"
        }
        if !ranges.isEmpty { rows.append(("Clock range, GHz", ranges.joined(separator: " · "))) }
        let platform = [info.platform, info.generation, info.revision.map { "rev \($0)" }].compactMap { $0 }
        if !platform.isEmpty { rows.append(("Platform", platform.joined(separator: " · "))) }
        rows.append(("Page · cache line", "\(Format.bytes(info.pageBytes)) · \(info.cacheLineBytes) B"))
        if let bits = info.streamingVectorBits { rows.append(("SME vector length", "\(bits) bits")) }
        rows.append(("Thermal state", Self.name(thermalState)))
        facts.rows = rows
    }

    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious, throttling"
        case .critical: "Critical, throttling"
        @unknown default: "Unknown"
        }
    }

    private func show(_ loads: [CoreLoad]) {
        coreGrid.loads = loads
        let busy = loads.isEmpty ? 0 : loads.map(\.active).reduce(0, +) / Double(loads.count) * 100
        coresCard.title = String(format: "Cores, live · clock in GHz · %.0f%% busy", busy)
        coreGrid.setAccessibilityLabel(String(format: "%d cores, %.0f percent busy", loads.count, busy))
        let state = ProcessInfo.processInfo.thermalState
        if state != thermalState {
            thermalState = state
            showFacts()
        }
    }

    // MARK: Benchmark

    func startBenchmark() {
        if !isRunning { toggleBenchmark() }
    }

    @objc func toggleBenchmark() {
        if let runner {
            runner.cancel()
            startButton.isEnabled = false
            status.stringValue = "Stopping…"
            return
        }
        let runner = CPUSuiteRunner(info: info, timing: timing)
        self.runner = runner
        measured = 0
        powerMode = nil
        powerTotals = [:]
        results.results = [:]
        results.power = [:]
        results.active = nil
        startButton.title = "Stop"
        progress.maxValue = Double(runner.cells.count)
        progress.doubleValue = 0
        progress.isHidden = false
        status.stringValue = "Starting…"
        runner.start { [weak self, weak runner] event in
            guard let self, let runner, self.runner === runner else { return }
            self.handle(event, of: runner)
        }
    }

    private func handle(_ event: CPUSuiteRunner.Event, of runner: CPUSuiteRunner) {
        switch event {
        case .started(let cell):
            if cell.mode != powerMode {
                powerMode = cell.mode
                skipPowerSample = true
            }
            results.active = (cell, nil)
            status.stringValue = "\(cell.workload.name): \(cell.mode.title(info))…"
        case .live(let cell, let rate):
            if results.active?.cell == cell { results.active = (cell, rate) }
        case .measured(let cell, let rate):
            results.results[cell] = rate
            measured += 1
            progress.doubleValue = Double(measured)
        case .finished(let cancelled):
            self.runner = nil
            powerMode = nil
            results.active = nil
            startButton.title = "Start"
            startButton.isEnabled = true
            progress.isHidden = true
            status.stringValue = cancelled ? "Stopped. Finished tests are kept below." : summary()
        }
    }

    private func record(_ sample: PowerSample) {
        guard let mode = powerMode, let watts = sample.thisAppCPU else { return }
        if skipPowerSample {
            skipPowerSample = false
            return
        }
        let total = powerTotals[mode] ?? (0, 0)
        powerTotals[mode] = (total.sum + watts, total.count + 1)
        results.power = powerTotals.mapValues { $0.sum / Double($0.count) }
    }

    private func summary() -> String {
        let scales = CPUWorkload.allCases.compactMap(results.scaling)
        guard !scales.isEmpty else { return "Done." }
        // Ratios average geometrically.
        let mean = exp(scales.map(log).reduce(0, +) / Double(scales.count))
        return String(format: "Done. All %d cores together do %.1f× the work of one P-core, averaged over the tests.", info.cores.count, mean)
    }

    private func showIdle() {
        progress.isHidden = true
        let seconds = CPUSuiteRunner(info: info, timing: timing).estimatedSeconds
        status.stringValue = String(format: "Five tests on one P-core, one E-core, then all cores. Takes about %.0f seconds.", seconds)
    }
}
