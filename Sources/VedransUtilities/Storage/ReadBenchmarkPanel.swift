import AppKit

/// Start/stop, a live speed chart and results for `FileReadBenchmark`.
final class ReadBenchmarkPanel: NSView {
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private let fileProgress = NSProgressIndicator()
    private let chart = TimeSeriesChartView()
    private let stats = FactListView()
    private let recentHeading = NSTextField(labelWithString: "Recent files, GB/s")
    private let recent = FactListView()

    private var benchmark: FileReadBenchmark?
    private var timer: Timer?
    private var meter = RateMeter()
    private var statistics = RunStatistics()
    private var startedAt: TimeInterval = 0
    private var lastSpeed = 0.0

    private static let sampleSeconds = 0.25

    var isRunning: Bool { benchmark != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        build()
        showIdle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        startButton.target = self
        startButton.action = #selector(toggle)
        startButton.bezelStyle = .push
        startButton.bezelColor = Theme.blue
        startButton.toolTip = "Reads large files already on this Mac, one at a time, straight from the SSD."
        status.font = Theme.text(12)
        status.textColor = Theme.inkSecondary
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        fileProgress.style = .bar
        fileProgress.isIndeterminate = false
        fileProgress.minValue = 0
        fileProgress.maxValue = 1
        fileProgress.controlSize = .small
        recentHeading.font = Theme.text(12, .semibold)
        recentHeading.textColor = Theme.inkSecondary

        chart.series = [.init(name: "Read", color: Theme.blue)]
        // A full run takes under ten seconds at SSD speeds.
        chart.windowSeconds = 15
        chart.gapSeconds = 1
        chart.emptyMessage = "Press Start to read files from the SSD"

        let toolbar = NSStackView(views: [startButton, status, fileProgress])
        toolbar.orientation = .horizontal
        toolbar.spacing = 12
        for item in [toolbar, chart, stats, recentHeading, recent] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            fileProgress.widthAnchor.constraint(equalToConstant: 160),

            chart.leadingAnchor.constraint(equalTo: leadingAnchor),
            chart.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            chart.bottomAnchor.constraint(equalTo: bottomAnchor),
            chart.trailingAnchor.constraint(equalTo: stats.leadingAnchor, constant: -20),

            stats.topAnchor.constraint(equalTo: chart.topAnchor, constant: 4),
            stats.trailingAnchor.constraint(equalTo: trailingAnchor),
            stats.widthAnchor.constraint(equalToConstant: 250),
            stats.heightAnchor.constraint(equalToConstant: 176),

            recentHeading.leadingAnchor.constraint(equalTo: stats.leadingAnchor),
            recentHeading.topAnchor.constraint(equalTo: stats.bottomAnchor, constant: 6),
            recent.leadingAnchor.constraint(equalTo: stats.leadingAnchor),
            recent.trailingAnchor.constraint(equalTo: stats.trailingAnchor),
            recent.topAnchor.constraint(equalTo: recentHeading.bottomAnchor, constant: 6),
            recent.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc func toggle() {
        if let benchmark {
            benchmark.stop()
        } else {
            start()
        }
    }

    private func start() {
        let benchmark = FileReadBenchmark()
        self.benchmark = benchmark
        meter = RateMeter()
        statistics = RunStatistics()
        lastSpeed = 0
        chart.clear()
        startedAt = ProcessInfo.processInfo.systemUptime
        startButton.title = "Stop"
        status.stringValue = "Looking for large files…"
        benchmark.start { [weak self] progress in self?.finished(progress) }
        let timer = Timer(timeInterval: Self.sampleSeconds, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let benchmark else { return }
        let (sample, progress) = benchmark.snapshot()
        // Only windows in which reads completed count, so a wait for the search isn't a slow read.
        if let rate = meter.update(sample) {
            lastSpeed = rate.total
            if progress.totalBytes > 0 { statistics.add(rate.total) }
            chart.append(time: ProcessInfo.processInfo.systemUptime - startedAt, values: [rate.total])
        }
        show(progress, isRunning: true)
    }

    private func finished(_ progress: FileReadBenchmark.Progress) {
        timer?.invalidate()
        timer = nil
        benchmark = nil
        startButton.title = "Start"
        lastSpeed = 0
        show(progress, isRunning: false)
    }

    private func showIdle() {
        status.stringValue = "Reads large files already on this Mac. Takes under ten seconds."
        fileProgress.isHidden = true
        stats.rows = [("Average", "—"), ("Peak", "—"), ("Data read", "—"), ("Files read", "—"), ("Skipped, in memory", "—"), ("Skipped, compressed", "—"), ("Request size", "32 MiB")]
        recent.rows = []
    }

    private func show(_ progress: FileReadBenchmark.Progress, isRunning: Bool) {
        if isRunning {
            fileProgress.isHidden = progress.currentFile == nil
            fileProgress.doubleValue = progress.currentFileFraction
            if let file = progress.currentFile {
                status.stringValue = "Reading \(file)"
            } else if progress.isSearching {
                status.stringValue = "Looking for large files… \(progress.filesFound) found"
            }
        } else {
            fileProgress.isHidden = true
            status.stringValue = progress.filesRead == 0
                ? "Found no large files that weren't already in memory."
                : "Read \(DriveFormat.bytes(progress.totalBytes)) from \(progress.filesRead) files at \(Format.rate(progress.averageGigabytesPerSecond)) on average."
        }
        stats.rows = [
            (isRunning ? "Now" : "Average", isRunning ? Format.rate(lastSpeed) : Format.rate(progress.averageGigabytesPerSecond)),
            (isRunning ? "Average" : "Peak, 0.25 s", isRunning ? Format.rate(progress.averageGigabytesPerSecond) : Format.rate(statistics.peak)),
            ("Data read", DriveFormat.bytes(progress.totalBytes)),
            ("Files read", "\(progress.filesRead) of \(progress.filesFound) found"),
            ("Skipped, in memory", "\(progress.skippedCached)"),
            ("Skipped, compressed", "\(progress.skippedCompressed)"),
        ] + (progress.skippedUnreadable > 0 ? [("Skipped, unreadable", "\(progress.skippedUnreadable)")] : [])
            + [("Request size", "32 MiB")]
        recent.rows = progress.recent.map { (Self.shorten($0.name), Format.number($0.gigabytesPerSecond)) }
    }

    /// Long hashed file names, shortened in the middle to fit the column.
    static func shorten(_ name: String, limit: Int = 26) -> String {
        guard name.count > limit else { return name }
        let half = (limit - 1) / 2
        return "\(name.prefix(half))…\(name.suffix(limit - 1 - half))"
    }
}
