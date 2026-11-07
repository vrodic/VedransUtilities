import AppKit

/// A selectable row with the operation's colour, name and description.
private final class OperationRow: NSButton {
    let operation: MemoryOperation

    init(_ operation: MemoryOperation, target: AnyObject, action: Selector) {
        self.operation = operation
        super.init(frame: .zero)
        self.target = target
        self.action = action
        title = operation.name
        isBordered = false
        setButtonType(.radio)
        wantsLayer = true
        toolTip = operation.detail
        heightAnchor.constraint(equalToConstant: 38).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        if selected {
            Theme.raised.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        operation.color.setFill()
        NSBezierPath(ovalIn: CGRect(x: 10, y: 15, width: 8, height: 8)).fill()
        Ink.draw(operation.name, at: CGPoint(x: 26, y: 4), font: Theme.text(12.5, selected ? .semibold : .regular), color: selected ? Theme.inkPrimary : Theme.inkSecondary)
        Ink.draw(operation.detail, at: CGPoint(x: 26, y: 20), font: Theme.text(10.5), color: Theme.inkMuted)
    }
}

final class MemoryViewController: NSViewController {
    private let controller = MemoryBenchController(topology: .current)
    private let power = PowerMonitor.shared
    private var topology: SystemTopology { controller.topology }

    // Controls
    private var operationRows: [OperationRow] = []
    private let blockSlider = NSSlider()
    private let blockValue = MemoryViewController.valueLabel()
    private let threadSlider = NSSlider()
    private let threadValue = MemoryViewController.valueLabel()
    private let coreControl = NSSegmentedControl()
    private let coreNote = MemoryViewController.noteLabel()
    private let levelHeading = MemoryViewController.heading("Data mostly lives in")
    private let levelView = MemoryLevelView()
    private let lanesCard = CardView(title: "Per thread, GB/s")
    private var cpuThreads = 4
    private let footprintNote = MemoryViewController.noteLabel()
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    private let sweepButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let progress = NSProgressIndicator()

    // Instruments
    private let gauge = GaugeView()
    private let liveChart = TimeSeriesChartView()
    private let lanes = ThreadLanesView()
    private let peakTile = StatTile(title: "Peak")
    private let averageTile = StatTile(title: "Average")
    private let stabilityTile = StatTile(title: "Stability")
    private let perThreadTile = StatTile(title: "Per thread")
    private let efficiencyTile = StatTile(title: "Efficiency")

    // Analysis
    private let analysisControl = NSSegmentedControl()
    private let analysisStatus = MemoryViewController.noteLabel()
    private let copyButton = NSButton(title: "Copy CSV", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear", target: nil, action: nil)
    private let curveChart = CurveChartView()
    private let heatmap = HeatmapView()
    private let scalingChart = CurveChartView()

    private var tileCountdown = 0
    private var lastMarkedOperation: MemoryOperation?

    private static func valueLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = Theme.digits(12.5, .semibold)
        label.textColor = Theme.inkPrimary
        label.alignment = .right
        return label
    }

    private static func noteLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = Theme.text(10.5)
        label.textColor = Theme.inkMuted
        label.isSelectable = false
        return label
    }

    private static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Theme.text(12, .semibold)
        label.textColor = Theme.inkSecondary
        return label
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.page.cgColor
        view = root
        buildLayout(in: root)
        wireController()
        refreshControls()
        reloadAnalysis()
    }

    // MARK: Layout

    private func buildLayout(in root: NSView) {
        let sidebar = buildSidebar()
        let gaugeCard = CardView()
        gaugeCard.fill(with: gauge)
        let chartCard = CardView(title: "Bandwidth, last 60 seconds")
        chartCard.fill(with: liveChart)
        lanesCard.fill(with: lanes)
        let analysisCard = buildAnalysisCard()

        let tileRow = NSStackView(views: [peakTile, averageTile, stabilityTile, perThreadTile, efficiencyTile])
        tileRow.distribution = .fillEqually
        tileRow.spacing = 10

        for item in [sidebar, gaugeCard, chartCard, lanesCard, tileRow, analysisCard] {
            item.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(item)
        }

        let margin: CGFloat = 12
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor, constant: margin),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -margin),
            sidebar.widthAnchor.constraint(equalToConstant: 268),

            gaugeCard.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 10),
            gaugeCard.topAnchor.constraint(equalTo: sidebar.topAnchor),
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

            analysisCard.leadingAnchor.constraint(equalTo: gaugeCard.leadingAnchor),
            analysisCard.topAnchor.constraint(equalTo: tileRow.bottomAnchor, constant: 10),
            analysisCard.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),

            lanesCard.leadingAnchor.constraint(equalTo: analysisCard.trailingAnchor, constant: 10),
            lanesCard.topAnchor.constraint(equalTo: analysisCard.topAnchor),
            lanesCard.bottomAnchor.constraint(equalTo: analysisCard.bottomAnchor),
            lanesCard.trailingAnchor.constraint(equalTo: chartCard.trailingAnchor),
            lanesCard.widthAnchor.constraint(equalToConstant: 212),
        ])

        liveChart.emptyMessage = "Press Start to begin measuring"
        gauge.setAccessibilityElement(true)
        gauge.setAccessibilityRole(.levelIndicator)
    }

    private func buildSidebar() -> NSView {
        let card = CardView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        let chip = NSTextField(labelWithString: "\(topology.chipName) · \(Format.bytes(topology.memoryBytes))")
        chip.font = Theme.text(12, .medium)
        chip.textColor = Theme.inkPrimary
        stack.addArrangedSubview(chip)
        let cores = NSTextField(labelWithString: "\(topology.performance.cores) performance, \(topology.efficiency.cores) efficiency cores")
        cores.font = Theme.text(10.5)
        cores.textColor = Theme.inkMuted
        stack.addArrangedSubview(cores)
        stack.setCustomSpacing(14, after: cores)

        let operationHeading = Self.heading("Operation")
        stack.addArrangedSubview(operationHeading)
        for operation in MemoryOperation.allCases {
            let row = OperationRow(operation, target: self, action: #selector(operationChanged(_:)))
            operationRows.append(row)
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }
        stack.setCustomSpacing(14, after: operationRows.last!)

        blockSlider.minValue = 0
        blockSlider.maxValue = Double(BlockSizes.all.count - 1)
        blockSlider.numberOfTickMarks = BlockSizes.all.count
        blockSlider.allowsTickMarkValuesOnly = true
        blockSlider.target = self
        blockSlider.action = #selector(blockChanged)
        blockSlider.setAccessibilityLabel("Block size")
        addSliderRow(to: stack, title: "Block size per thread", value: blockValue, slider: blockSlider)

        threadSlider.minValue = 1
        threadSlider.allowsTickMarkValuesOnly = true
        threadSlider.target = self
        threadSlider.action = #selector(threadsChanged)
        threadSlider.setAccessibilityLabel("Threads")
        addSliderRow(to: stack, title: "Threads", value: threadValue, slider: threadSlider)

        coreControl.segmentCount = Processor.allCases.count
        for processor in Processor.allCases { coreControl.setLabel(processor.segmentName, forSegment: processor.rawValue) }
        coreControl.segmentDistribution = .fillEqually
        coreControl.trackingMode = .selectOne
        coreControl.target = self
        coreControl.action = #selector(coresChanged)
        coreControl.toolTip = "macOS can't pin threads to cores, so the CPU choices set quality of service, which steers threads onto that core type. GPU runs Metal compute kernels."
        stack.addArrangedSubview(coreControl)
        coreControl.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        coreControl.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        stack.setCustomSpacing(4, after: coreControl)
        addFullWidth(coreNote, to: stack)
        stack.setCustomSpacing(14, after: coreNote)

        stack.addArrangedSubview(levelHeading)
        levelView.toolTip = "An estimate from cache sizes, block size and how many threads share a cluster's L2."
        addFullWidth(levelView, to: stack)
        levelView.heightAnchor.constraint(equalToConstant: 44).isActive = true
        addFullWidth(footprintNote, to: stack)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        stack.addArrangedSubview(spacer)

        startButton.target = self
        startButton.action = #selector(startPressed)
        startButton.bezelStyle = .push
        startButton.controlSize = .large
        startButton.bezelColor = Theme.blue
        startButton.keyEquivalent = "\r"
        addFullWidth(startButton, to: stack)
        stack.setCustomSpacing(8, after: startButton)

        sweepButton.autoenablesItems = false
        sweepButton.addItem(withTitle: "Run a Sweep")
        for kind in SweepKind.allCases { sweepButton.addItem(withTitle: kind.title) }
        sweepButton.target = self
        sweepButton.action = #selector(sweepPicked)
        sweepButton.controlSize = .large
        addFullWidth(sweepButton, to: stack)

        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        progress.isHidden = true
        addFullWidth(progress, to: stack)

        card.fill(with: stack)
        return card
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
    }

    private func addSliderRow(to stack: NSStackView, title: String, value: NSTextField, slider: NSSlider) {
        let header = NSStackView(views: [Self.heading(title), NSView(), value])
        header.orientation = .horizontal
        addFullWidth(header, to: stack)
        addFullWidth(slider, to: stack)
        stack.setCustomSpacing(12, after: slider)
    }

    private func buildAnalysisCard() -> NSView {
        let card = CardView()
        analysisControl.segmentCount = 3
        for (index, label) in ["Block Curve", "Bandwidth Map", "Thread Scaling"].enumerated() {
            analysisControl.setLabel(label, forSegment: index)
        }
        analysisControl.trackingMode = .selectOne
        analysisControl.selectedSegment = 0
        analysisControl.target = self
        analysisControl.action = #selector(analysisTabChanged)

        analysisStatus.maximumNumberOfLines = 1
        analysisStatus.lineBreakMode = .byTruncatingTail
        analysisStatus.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        for (button, action) in [(copyButton, #selector(copyCSV)), (clearButton, #selector(clearResults))] {
            button.target = self
            button.action = action
            button.bezelStyle = .push
            button.controlSize = .small
        }
        copyButton.toolTip = "Copy every measured value, the table version of these charts."

        let toolbar = NSStackView(views: [analysisControl, analysisStatus, NSView(), copyButton, clearButton])
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        for chart in [curveChart, heatmap, scalingChart] as [NSView] {
            chart.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(chart)
            NSLayoutConstraint.activate([
                chart.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                chart.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                chart.topAnchor.constraint(equalTo: holder.topAnchor),
                chart.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            ])
        }
        card.content.addSubview(toolbar)
        card.content.addSubview(holder)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: card.content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: card.content.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: card.content.topAnchor),
            holder.leadingAnchor.constraint(equalTo: card.content.leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: card.content.trailingAnchor),
            holder.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            holder.bottomAnchor.constraint(equalTo: card.content.bottomAnchor),
        ])

        curveChart.xTitle = "Block size per thread"
        curveChart.emptyMessage = "Run a block-size sweep to draw the memory hierarchy"
        curveChart.onSelect = { [weak self] index in self?.selectBlock(BlockSizes.sweep[index]) }
        scalingChart.xTitle = "Threads"
        scalingChart.emptyMessage = "Run a thread-scaling sweep to see how bandwidth grows"
        scalingChart.onSelect = { [weak self] index in self?.selectThreads(index + 1) }
        heatmap.emptyMessage = "Run a full map, or let live runs fill it in"
        heatmap.onSelect = { [weak self] cell in
            guard let self else { return }
            var config = self.controller.config
            config.blockBytes = BlockSizes.sweep[cell.column]
            config.threads = cell.row + 1
            self.apply(config)
        }
        analysisTabChanged()
        return card
    }

    // MARK: Controller

    private func wireController() {
        controller.onActivity = { [weak self] activity in self?.activityChanged(activity) }
        controller.onResultsChanged = { [weak self] in
            self?.reloadAnalysis()
            self?.updateSweepTiles()
        }
        controller.onError = { [weak self] message in self?.showError(message) }
        controller.onEngineStarted = { [weak self] config in
            guard let self else { return }
            self.gauge.reset(keepScale: true)
            self.gauge.tint = config.operation.color
            self.gauge.caption = config.summary
            self.lanes.tint = config.operation.color
            let sweeping = if case .sweeping = self.controller.activity { true } else { false }
            // A sweep changes configuration too fast to label each one, so it
            // only marks where a new operation begins.
            if !sweeping || config.operation != self.lastMarkedOperation {
                self.liveChart.addMarker(.init(
                    time: self.controller.now,
                    label: sweeping ? config.operation.name : config.summary,
                    color: config.operation.color
                ))
            }
            self.lastMarkedOperation = config.operation
            self.updateActiveCell(config)
        }
        controller.onSample = { [weak self] sample in self?.handle(sample) }
    }

    /// Averages across a sweep's mixed configurations would mean nothing, so a
    /// sweep reports only its fastest result and leaves the run statistics empty.
    private func updateSweepTiles() {
        guard case .sweeping = controller.activity else { return }
        guard let best = controller.results.values.max(by: { $0.value < $1.value }) else { return }
        peakTile.value = Format.rate(best.value)
        peakTile.caption = best.key.summary
        for tile in [averageTile, stabilityTile, perThreadTile, efficiencyTile] {
            tile.value = "—"
            tile.caption = "Live runs only"
        }
    }

    private func handle(_ sample: MemoryBenchController.Sample) {
        gauge.isActive = true
        gauge.set(value: sample.gigabytesPerSecond, peak: sample.statistics.peak)
        liveChart.append(time: sample.time, values: [sample.gigabytesPerSecond])
        lanes.values = sample.perThread

        tileCountdown -= 1
        guard tileCountdown <= 0 else { return }
        tileCountdown = 5
        let stats = sample.statistics
        guard stats.count > 0 else { return }
        peakTile.value = Format.rate(stats.peak)
        peakTile.caption = sample.config.summary
        averageTile.value = Format.rate(stats.mean)
        averageTile.caption = "\(Format.volume(sample.totalBytes)) moved"
        stabilityTile.value = String(format: "± %.1f%%", stats.jitterPercent)
        stabilityTile.caption = "Low \(Format.rate(stats.minimum))"
        let perThread = stats.mean / Double(sample.config.threads)
        let lineTime = String(format: "%.2f ns", 128 / max(perThread, 0.0001))
        if sample.config.processor == .gpu {
            perThreadTile.title = "Per line"
            perThreadTile.value = lineTime
            perThreadTile.caption = "GPU time per 128 bytes"
        } else {
            perThreadTile.title = "Per thread"
            perThreadTile.value = Format.rate(perThread)
            perThreadTile.caption = "\(lineTime) per 128-byte line"
        }
        if let reading = power.latest, let system = reading.system, system > 0 {
            efficiencyTile.value = String(format: "%@ GB/J", Format.number(stats.mean / system))
            efficiencyTile.caption = sample.config.processor == .gpu
                ? "\(Format.watts(system)) system, \(Format.watts(reading.soc)) SoC"
                : "\(Format.watts(system)) system, \(Format.watts(reading.thisAppCPU)) app CPU"
        }
    }

    private func activityChanged(_ activity: MemoryBenchController.Activity) {
        switch activity {
        case .idle:
            startButton.title = "Start"
            progress.isHidden = true
            gauge.isActive = false
            gauge.set(value: 0, peak: 0)
            gauge.caption = ""
            lanes.values = []
            heatmap.active = nil
            analysisStatus.stringValue = ""
        case .preparing:
            startButton.title = "Stop"
            gauge.caption = "Preparing \(Format.bytes(controller.effectiveConfig.footprintBytes))…"
        case .live:
            startButton.title = "Stop"
        case let .sweeping(done, total, kind):
            startButton.title = "Cancel Sweep"
            progress.isHidden = false
            progress.doubleValue = Double(done) / Double(max(1, total))
            analysisStatus.stringValue = "\(done) of \(total)"
            if done == 0 { selectAnalysisTab(for: kind) }
        }
        refreshControls()
    }

    private func showError(_ message: String) {
        footprintNote.stringValue = message
        footprintNote.textColor = Theme.inkPrimary
    }

    private func selectAnalysisTab(for kind: SweepKind) {
        switch kind {
        case .blocks, .blocksAllOperations: analysisControl.selectedSegment = 0
        case .map: analysisControl.selectedSegment = 1
        case .threads: analysisControl.selectedSegment = 2
        }
        analysisTabChanged()
    }

    private func refreshControls() {
        let config = controller.config
        let effective = controller.effectiveConfig
        for row in operationRows {
            row.state = row.operation == config.operation ? .on : .off
            row.needsDisplay = true
        }
        blockSlider.doubleValue = Double(BlockSizes.all.firstIndex(of: config.blockBytes) ?? 0)
        blockValue.stringValue = Format.bytes(config.blockBytes)
        let isGPU = config.processor == .gpu
        let maxThreads = topology.maxThreads(for: config.processor)
        // A slider needs a range of at least one step, even while the GPU disables it.
        threadSlider.maxValue = Double(max(2, maxThreads))
        threadSlider.numberOfTickMarks = max(2, maxThreads)
        threadSlider.doubleValue = Double(config.threads)
        threadValue.stringValue = isGPU ? "Set by GPU" : "\(config.threads) of \(maxThreads)"
        coreControl.selectedSegment = config.processor.rawValue
        coreNote.stringValue = isGPU
            ? "Metal compute on private buffers. The GPU schedules its own threads."
            : "Steered by quality of service. macOS can't pin threads."

        levelHeading.isHidden = isGPU
        levelView.isHidden = isGPU
        levelView.level = topology.level(for: effective)
        if let cluster = topology.cluster(for: effective.processor) {
            levelView.sizes = [Format.bytes(cluster.l1Bytes), Format.bytes(cluster.l2Bytes), Format.bytes(topology.memoryBytes)]
        }
        lanesCard.title = isGPU ? "GPU total, GB/s" : "Per thread, GB/s"
        footprintNote.textColor = Theme.inkMuted
        if effective.blockBytes != config.blockBytes {
            footprintNote.stringValue = "Block reduced to \(Format.bytes(effective.blockBytes)) to stay under 60% of memory."
        } else {
            footprintNote.stringValue = "Allocates \(Format.bytes(effective.footprintBytes)) in total."
        }

        var isSweeping = false
        if case .sweeping = controller.activity { isSweeping = true }
        let controls: [NSControl] = operationRows + [blockSlider, threadSlider, coreControl, sweepButton, clearButton]
        controls.forEach { $0.isEnabled = !isSweeping }
        if isGPU { threadSlider.isEnabled = false }

        // The other sweeps and views vary the thread count, which the GPU doesn't have.
        let threadBasedKinds: [SweepKind] = [.threads, .map]
        for kind in threadBasedKinds {
            sweepButton.item(withTitle: kind.title)?.isEnabled = !isGPU
        }
        analysisControl.setEnabled(!isGPU, forSegment: 1)
        analysisControl.setEnabled(!isGPU, forSegment: 2)
        if isGPU, analysisControl.selectedSegment != 0 {
            analysisControl.selectedSegment = 0
            analysisTabChanged()
        }
        reloadSelections()
    }

    // MARK: Actions

    @objc func toggleRun() { startPressed() }

    @objc private func startPressed() {
        if case .idle = controller.activity { resetStats() }
        controller.toggleLive()
    }

    func selectForLaunch(_ processor: Processor) {
        coreControl.selectedSegment = processor.rawValue
        coresChanged()
    }

    func startFromLaunch(sweep kind: SweepKind?) {
        if let kind {
            controller.startSweep(kind)
        } else if case .idle = controller.activity {
            startPressed()
        }
    }

    private func resetStats() {
        gauge.reset()
        for tile in [peakTile, averageTile, stabilityTile, perThreadTile, efficiencyTile] {
            tile.value = "—"
            tile.caption = ""
        }
    }

    @objc private func operationChanged(_ sender: OperationRow) {
        var config = controller.config
        config.operation = sender.operation
        apply(config)
        reloadAnalysis()
    }

    @objc private func blockChanged() {
        selectBlock(BlockSizes.all[Int(blockSlider.doubleValue.rounded())])
    }

    @objc private func threadsChanged() {
        selectThreads(Int(threadSlider.doubleValue.rounded()))
    }

    @objc private func coresChanged() {
        var config = controller.config
        if config.processor != .gpu { cpuThreads = config.threads }
        config.processor = Processor(rawValue: coreControl.selectedSegment) ?? .performance
        config.threads = min(cpuThreads, topology.maxThreads(for: config.processor))
        if config.processor == .gpu { config.threads = 1 }
        apply(config)
        reloadAnalysis()
    }

    private func selectBlock(_ block: UInt64) {
        var config = controller.config
        config.blockBytes = block
        apply(config)
    }

    private func selectThreads(_ threads: Int) {
        var config = controller.config
        config.threads = threads
        apply(config)
        reloadAnalysis()
    }

    private func apply(_ config: BenchmarkConfig) {
        var isSweeping = false
        if case .sweeping = controller.activity { isSweeping = true }
        guard !isSweeping else { return }
        controller.update(config)
        refreshControls()
    }

    @objc private func sweepPicked() {
        let index = sweepButton.indexOfSelectedItem - 1
        guard SweepKind.allCases.indices.contains(index) else { return }
        resetStats()
        controller.startSweep(SweepKind.allCases[index])
    }

    @objc private func analysisTabChanged() {
        let selected = analysisControl.selectedSegment
        curveChart.isHidden = selected != 0
        heatmap.isHidden = selected != 1
        scalingChart.isHidden = selected != 2
    }

    @objc private func copyCSV() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.results.csv, forType: .string)
    }

    @objc private func clearResults() {
        controller.results.clear()
        reloadAnalysis()
    }

    // MARK: Analysis

    private func reloadAnalysis() {
        let config = controller.config
        let results = controller.results
        let blocks = BlockSizes.sweep
        let labels = blocks.map(Self.shortBytes)

        // Block curve: every operation, at the selected thread count.
        curveChart.xLabels = labels
        curveChart.series = MemoryOperation.allCases.compactMap { operation in
            let values = blocks.map { results.values[BenchmarkConfig(operation: operation, blockBytes: $0, threads: config.threads, processor: config.processor)] }
            guard values.contains(where: { $0 != nil }) else { return nil }
            return .init(name: operation.name, color: operation.color, values: values)
        }
        func guide(_ bytes: UInt64, _ label: String) -> CurveChartView.Guide? {
            guard bytes > 0 else { return nil }
            return .init(index: log2(Double(bytes)) - log2(Double(blocks[0])), label: label)
        }
        if let cluster = topology.cluster(for: config.processor) {
            curveChart.guides = [guide(cluster.l1Bytes, "L1"), guide(cluster.l2Bytes, "L2")].compactMap { $0 }
        } else {
            curveChart.guides = []
        }

        // Scaling: this operation and block size, across thread counts.
        let threadCounts = Array(1...topology.maxThreads(for: config.processor))
        scalingChart.xLabels = threadCounts.map(String.init)
        let scaling = threadCounts.map {
            results.values[BenchmarkConfig(operation: config.operation, blockBytes: config.blockBytes, threads: $0, processor: config.processor)]
        }
        var scalingSeries: [CurveChartView.Series] = [.init(name: config.operation.name, color: config.operation.color, values: scaling)]
        if let single = scaling.first ?? nil {
            scalingSeries.append(.init(
                name: "Linear from 1 thread",
                color: Theme.inkMuted,
                values: threadCounts.map { single * Double($0) },
                isReference: true
            ))
        }
        scalingChart.series = scalingSeries

        // Map: this operation across both axes.
        heatmap.columns = labels
        heatmap.rows = threadCounts.map(String.init)
        var cells: [HeatmapView.Cell: Double] = [:]
        var skippedCells = Set<HeatmapView.Cell>()
        for (column, block) in blocks.enumerated() {
            for threads in threadCounts {
                let key = BenchmarkConfig(operation: config.operation, blockBytes: block, threads: threads, processor: config.processor)
                let cell = HeatmapView.Cell(column: column, row: threads - 1)
                if let value = results.values[key] { cells[cell] = value }
                if results.skipped.contains(key) { skippedCells.insert(cell) }
            }
        }
        heatmap.values = cells
        heatmap.skipped = skippedCells
        reloadSelections()
    }

    private func reloadSelections() {
        let config = controller.config
        let column = BlockSizes.sweep.firstIndex(of: config.blockBytes)
        curveChart.selectedIndex = column
        scalingChart.selectedIndex = config.threads - 1
        heatmap.selected = column.map { .init(column: $0, row: config.threads - 1) }
    }

    private func updateActiveCell(_ config: BenchmarkConfig) {
        var isSweeping = false
        if case .sweeping = controller.activity { isSweeping = true }
        guard isSweeping, let column = BlockSizes.sweep.firstIndex(of: config.blockBytes) else {
            heatmap.active = nil
            return
        }
        heatmap.active = .init(column: column, row: config.threads - 1)
    }

    /// "4K", "16M", "1G": axis labels short enough to fit every block size.
    private static func shortBytes(_ bytes: UInt64) -> String {
        if bytes >= 1 << 30 { return "\(bytes >> 30)G" }
        if bytes >= 1 << 20 { return "\(bytes >> 20)M" }
        return "\(bytes >> 10)K"
    }
}
