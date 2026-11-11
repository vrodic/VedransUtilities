import CMemBench
import Foundation

enum MemoryOperation: Int, CaseIterable, Sendable {
    case read, write, copy, triad, random

    var name: String {
        switch self {
        case .read: "Read"
        case .write: "Write"
        case .copy: "Copy"
        case .triad: "Triad"
        case .random: "Random"
        }
    }

    var detail: String {
        switch self {
        case .read: "Sequential 256-byte loads"
        case .write: "Sequential 256-byte stores"
        case .copy: "A → B, counts read + write"
        case .triad: "A = B + s·C, counts all three"
        case .random: "Random loads, one line each"
        }
    }

    var bufferCount: Int { Int(mb_buffers_for_op(Int32(rawValue))) }
}

/// What runs the test. CPU choices map onto a core type, and raw values 0 and 1
/// match the C engine's MB_CORES constants.
enum Processor: Int, CaseIterable, Sendable {
    case performance, efficiency, gpu

    var name: String {
        switch self {
        case .performance: "Performance"
        case .efficiency: "Efficiency"
        case .gpu: "GPU"
        }
    }

    var segmentName: String {
        switch self {
        case .performance: "P-cores"
        case .efficiency: "E-cores"
        case .gpu: "GPU"
        }
    }
}

struct BenchmarkConfig: Hashable, Sendable {
    var operation: MemoryOperation
    var blockBytes: UInt64
    var threads: Int
    var processor: Processor

    var footprintBytes: UInt64 { blockBytes * UInt64(threads) * UInt64(operation.bufferCount) }

    var summary: String {
        let unit = switch processor {
        case .performance: "\(threads)P"
        case .efficiency: "\(threads)E"
        case .gpu: "GPU"
        }
        return "\(operation.name) · \(Format.bytes(blockBytes)) · \(unit)"
    }
}

enum BlockSizes {
    /// 4 KiB to 2 GiB, doubling.
    static let all: [UInt64] = (12...31).map { UInt64(1) << $0 }
    /// Sweeps stop at 1 GiB: past the caches, larger blocks add time, not information.
    static let sweep: [UInt64] = all.filter { $0 <= 1 << 30 }
}

struct EngineSnapshot {
    var perThread: [UInt64]
    var totalBytes: UInt64
    var nanoseconds: UInt64
}

/// A running test. `snapshot` must be safe to race `stop`.
protocol BandwidthEngine: AnyObject {
    var config: BenchmarkConfig { get }
    /// Blocks while buffers are prepared. False if that failed.
    func waitUntilReady() -> Bool
    func snapshot() -> EngineSnapshot?
    func stop()
}

func makeBandwidthEngine(_ config: BenchmarkConfig) -> BandwidthEngine? {
    config.processor == .gpu ? GPUBenchmarkEngine(config: config) : BenchmarkEngine(config: config)
}

/// The CPU engine: a thread-safe wrapper over the C workers.
final class BenchmarkEngine: BandwidthEngine {
    let config: BenchmarkConfig
    private let lock = NSLock()
    private var engine: OpaquePointer?

    init?(config: BenchmarkConfig) {
        guard config.processor != .gpu else { return nil }
        self.config = config
        let raw = mb_config(
            op: Int32(config.operation.rawValue),
            cores: Int32(config.processor.rawValue),
            threads: Int32(config.threads),
            block_bytes: config.blockBytes
        )
        guard let started = mb_start(raw) else { return nil }
        engine = started
    }

    deinit { stop() }

    func waitUntilReady() -> Bool {
        lock.lock()
        let current = engine
        lock.unlock()
        guard let current else { return false }
        return mb_wait_ready(current)
    }

    func snapshot() -> EngineSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let engine else { return nil }
        var perThread = [UInt64](repeating: 0, count: config.threads)
        let total = mb_snapshot(engine, &perThread, Int32(config.threads))
        return EngineSnapshot(perThread: perThread, totalBytes: total, nanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    func stop() {
        lock.lock()
        let current = engine
        engine = nil
        lock.unlock()
        if let current { mb_stop(current) }
    }
}

/// Turns consecutive cumulative snapshots into rates, in decimal GB/s.
struct RateMeter {
    private var previous: EngineSnapshot?

    mutating func update(_ snapshot: EngineSnapshot) -> (total: Double, perThread: [Double])? {
        defer { previous = snapshot }
        guard let previous, snapshot.nanoseconds > previous.nanoseconds,
              previous.perThread.count == snapshot.perThread.count else { return nil }
        let nanoseconds = Double(snapshot.nanoseconds - previous.nanoseconds)
        let perThread = zip(snapshot.perThread, previous.perThread).map { Double($0 - $1) / nanoseconds }
        return (Double(snapshot.totalBytes - previous.totalBytes) / nanoseconds, perThread)
    }
}

/// Mean, spread and extremes for one uninterrupted run (Welford's algorithm).
struct RunStatistics {
    private(set) var count = 0
    private(set) var mean = 0.0
    private(set) var peak = 0.0
    private(set) var minimum = Double.infinity
    private var m2 = 0.0

    mutating func add(_ value: Double) {
        count += 1
        let delta = value - mean
        mean += delta / Double(count)
        m2 += delta * (value - mean)
        peak = max(peak, value)
        minimum = min(minimum, value)
    }

    /// Standard deviation as a percentage of the mean.
    var jitterPercent: Double {
        guard count > 1, mean > 0 else { return 0 }
        return (m2 / Double(count - 1)).squareRoot() / mean * 100
    }
}

/// Best measured bandwidth per configuration, shared by every analysis view.
final class BenchmarkResults {
    private(set) var values: [BenchmarkConfig: Double] = [:]
    private(set) var skipped: Set<BenchmarkConfig> = []

    func record(_ config: BenchmarkConfig, gigabytesPerSecond: Double) {
        values[config] = gigabytesPerSecond
        skipped.remove(config)
    }

    func markSkipped(_ config: BenchmarkConfig) { skipped.insert(config) }

    func clear() {
        values.removeAll()
        skipped.removeAll()
    }

    var csv: String {
        let header = "operation,processor,threads,block_bytes,gb_per_s"
        let rows = values.sorted {
            ($0.key.operation.rawValue, $0.key.processor.rawValue, $0.key.threads, $0.key.blockBytes)
                < ($1.key.operation.rawValue, $1.key.processor.rawValue, $1.key.threads, $1.key.blockBytes)
        }.map {
            "\($0.key.operation.name),\($0.key.processor.name),\($0.key.threads),\($0.key.blockBytes),\(String(format: "%.3f", $0.value))"
        }
        return ([header] + rows).joined(separator: "\n") + "\n"
    }
}

enum SweepKind: CaseIterable {
    case blocks, blocksAllOperations, threads, map

    var title: String {
        switch self {
        case .blocks: "Block sizes, this operation"
        case .blocksAllOperations: "Block sizes, all operations"
        case .threads: "Thread scaling"
        case .map: "Full map (block × threads)"
        }
    }
}

enum SweepPlan {
    static func configs(_ kind: SweepKind, from base: BenchmarkConfig, maxThreads: Int) -> [BenchmarkConfig] {
        func at(_ op: MemoryOperation, _ block: UInt64, _ threads: Int) -> BenchmarkConfig {
            BenchmarkConfig(operation: op, blockBytes: block, threads: threads, processor: base.processor)
        }
        switch kind {
        case .blocks:
            return BlockSizes.sweep.map { at(base.operation, $0, base.threads) }
        case .blocksAllOperations:
            return MemoryOperation.allCases.flatMap { op in BlockSizes.sweep.map { at(op, $0, base.threads) } }
        case .threads:
            return (1...maxThreads).map { at(base.operation, base.blockBytes, $0) }
        case .map:
            return (1...maxThreads).flatMap { t in BlockSizes.sweep.map { at(base.operation, $0, t) } }
        }
    }
}

/// Runs a plan on its own thread, one configuration at a time.
final class SweepRunner {
    private static let windows = 5
    private static let windowSeconds = 0.04
    private static let steadyTolerance = 0.05
    private static let maximumSeconds = 3.0
    private static let settleBytesPerSecond = 6e9

    private let plan: [BenchmarkConfig]
    private let footprintLimit: UInt64
    private let cancelled = NSLock()
    private var isCancelled = false

    init(plan: [BenchmarkConfig], footprintLimit: UInt64) {
        self.plan = plan
        self.footprintLimit = footprintLimit
    }

    func cancel() {
        cancelled.lock()
        isCancelled = true
        cancelled.unlock()
    }

    private var shouldStop: Bool {
        cancelled.lock()
        defer { cancelled.unlock() }
        return isCancelled
    }

    /// Callbacks arrive on the main queue. A nil result means the configuration
    /// was skipped for exceeding the memory limit, or failed to allocate.
    func start(
        onEngine: @escaping (BandwidthEngine?, Int) -> Void,
        onResult: @escaping (BenchmarkConfig, Double?) -> Void,
        onFinish: @escaping (_ cancelled: Bool) -> Void
    ) {
        let thread = Thread { [self] in
            for (index, config) in plan.enumerated() {
                if shouldStop { break }
                if config.footprintBytes > footprintLimit {
                    DispatchQueue.main.async { onResult(config, nil) }
                    continue
                }
                guard let engine = makeBandwidthEngine(config), engine.waitUntilReady() else {
                    DispatchQueue.main.async { onResult(config, nil) }
                    continue
                }
                DispatchQueue.main.async { onEngine(engine, index) }
                let value = measure(engine)
                DispatchQueue.main.async { onEngine(nil, index) }
                engine.stop()
                // An interrupted measurement isn't a result, nor a skipped cell.
                if shouldStop { break }
                DispatchQueue.main.async { onResult(config, value) }
            }
            let wasCancelled = shouldStop
            DispatchQueue.main.async { onFinish(wasCancelled) }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Samples until the rate is steady, then reports the median of the last few
    /// windows. The first large allocation in a while can run far below sustained
    /// speed for over a second, with brief plateaus that look steady. So big
    /// footprints must also be watched for a time proportional to their size.
    private func measure(_ engine: BandwidthEngine) -> Double? {
        var rates: [Double] = []
        var meter = RateMeter()
        guard let first = engine.snapshot() else { return nil }
        _ = meter.update(first)
        let maximumWindows = Int(Self.maximumSeconds / Self.windowSeconds)
        let minimumSeconds = min(Self.maximumSeconds, Double(engine.config.footprintBytes) / Self.settleBytesPerSecond)
        let minimumWindows = max(Self.windows, Int(minimumSeconds / Self.windowSeconds))
        for _ in 0..<maximumWindows {
            if shouldStop { return nil }
            Thread.sleep(forTimeInterval: Self.windowSeconds)
            guard let next = engine.snapshot() else { return nil }
            // A window with no completed GPU work has no new rate, so it's skipped.
            guard let rate = meter.update(next) else { continue }
            rates.append(rate.total)
            if rates.count >= minimumWindows, Self.isSteady(rates.suffix(Self.windows)) { break }
        }
        return rates.isEmpty ? nil : Self.median(rates.suffix(Self.windows))
    }

    static func isSteady(_ rates: ArraySlice<Double>) -> Bool {
        guard let low = rates.min(), let high = rates.max(), high > 0 else { return false }
        return (high - low) / high <= steadyTolerance
    }

    private static func median(_ rates: ArraySlice<Double>) -> Double {
        rates.sorted()[rates.count / 2]
    }
}

/// Drives a live run or sweep from the main thread and publishes samples.
final class MemoryBenchController {
    enum Activity: Equatable {
        case idle
        case preparing
        case live
        case sweeping(done: Int, total: Int, kind: SweepKind)
    }

    struct Sample {
        var time: TimeInterval
        var gigabytesPerSecond: Double
        var perThread: [Double]
        var statistics: RunStatistics
        var totalBytes: UInt64
        var config: BenchmarkConfig
    }

    let topology: SystemTopology
    let results = BenchmarkResults()

    var onSample: ((Sample) -> Void)?
    var onActivity: ((Activity) -> Void)?
    var onResultsChanged: (() -> Void)?
    var onEngineStarted: ((BenchmarkConfig) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var config: BenchmarkConfig
    private(set) var activity: Activity = .idle {
        didSet { if activity != oldValue { onActivity?(activity) } }
    }

    private let engineQueue = DispatchQueue(label: "memorybench.engine", qos: .userInitiated)
    private var engine: BandwidthEngine?
    private var generation = 0
    private var restartWork: DispatchWorkItem?
    private var timer: Timer?
    private var meter = RateMeter()
    private var statistics = RunStatistics()
    private var attachedAt: TimeInterval = 0
    private var sweep: SweepRunner?
    private let clockStart = ProcessInfo.processInfo.systemUptime

    /// Rates during the first moments of a run reflect ramp-up, not sustained speed.
    private static let settleSeconds = 0.3
    /// A live run must last this long to count as a measured result.
    private static let minimumResultSeconds = 1.0

    init(topology: SystemTopology) {
        self.topology = topology
        config = BenchmarkConfig(
            operation: .read,
            blockBytes: 1 << 28,
            threads: min(4, topology.maxThreads(for: .performance)),
            processor: .performance
        )
    }

    var isBusy: Bool { activity != .idle }
    var footprintLimit: UInt64 { topology.memoryBytes / 10 * 6 }

    /// The configuration that will actually run: blocks shrink to fit the limit.
    var effectiveConfig: BenchmarkConfig {
        var result = config
        while result.footprintBytes > footprintLimit, result.blockBytes > 4096 { result.blockBytes /= 2 }
        return result
    }

    func update(_ newConfig: BenchmarkConfig) {
        guard newConfig != config else { return }
        config = newConfig
        guard activity == .live || activity == .preparing else { return }
        // Sliders fire continuously, so coalesce before reallocating buffers.
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startLive() }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func toggleLive() {
        switch activity {
        case .idle: startLive()
        case .sweeping: cancelSweep()
        case .preparing, .live: stop()
        }
    }

    func startLive() {
        restartWork?.cancel()
        detachEngine()
        generation += 1
        let current = generation
        let wanted = effectiveConfig
        activity = .preparing
        engineQueue.async { [weak self] in
            let started = makeBandwidthEngine(wanted)
            let ready = started?.waitUntilReady() ?? false
            DispatchQueue.main.async {
                guard let self, self.generation == current else {
                    self?.engineQueue.async { started?.stop() }
                    return
                }
                guard ready, let started else {
                    self.engineQueue.async { started?.stop() }
                    self.activity = .idle
                    self.onError?("Couldn't allocate \(Format.bytes(wanted.footprintBytes)) for this test.")
                    return
                }
                self.attach(started)
                self.activity = .live
            }
        }
    }

    func stop() {
        restartWork?.cancel()
        generation += 1
        detachEngine()
        stopTimer()
        activity = .idle
    }

    func startSweep(_ kind: SweepKind) {
        stop()
        let plan = SweepPlan.configs(kind, from: effectiveConfig, maxThreads: topology.maxThreads(for: effectiveConfig.processor))
        let runner = SweepRunner(plan: plan, footprintLimit: footprintLimit)
        sweep = runner
        generation += 1
        startTimer()
        var finished = 0
        activity = .sweeping(done: 0, total: plan.count, kind: kind)
        // Wait for any live engine's teardown so its memory is free first.
        engineQueue.async { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.sweep === runner else { return }
                runner.start(
                    onEngine: { [weak self] engine, _ in
                        guard let self, self.sweep === runner else { return }
                        self.engine = engine
                        self.meter = RateMeter()
                        self.statistics = RunStatistics()
                        self.attachedAt = self.now
                        if let engine { self.onEngineStarted?(engine.config) }
                    },
                    onResult: { [weak self] config, value in
                        guard let self, self.sweep === runner else { return }
                        if let value {
                            self.results.record(config, gigabytesPerSecond: value)
                        } else {
                            self.results.markSkipped(config)
                        }
                        finished += 1
                        self.activity = .sweeping(done: finished, total: plan.count, kind: kind)
                        self.onResultsChanged?()
                    },
                    onFinish: { [weak self] _ in
                        guard let self, self.sweep === runner else { return }
                        self.sweep = nil
                        self.engine = nil
                        self.stopTimer()
                        self.activity = .idle
                        self.onResultsChanged?()
                    }
                )
            }
        }
    }

    func cancelSweep() { sweep?.cancel() }

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime - clockStart }

    private func attach(_ newEngine: BandwidthEngine) {
        engine = newEngine
        meter = RateMeter()
        statistics = RunStatistics()
        attachedAt = now
        onEngineStarted?(newEngine.config)
        startTimer()
    }

    private func detachEngine() {
        recordLiveResult()
        guard let old = engine else { return }
        engine = nil
        engineQueue.async { old.stop() }
    }

    /// A sustained live run is a real measurement, so it joins the analysis views.
    private func recordLiveResult() {
        guard let engine, activity == .live,
              now - attachedAt >= Self.minimumResultSeconds, statistics.count > 0 else { return }
        results.record(engine.config, gigabytesPerSecond: statistics.mean)
        onResultsChanged?()
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in self?.tick() }
        // Common modes keep the meter moving while a slider is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let engine, let snapshot = engine.snapshot(), let rate = meter.update(snapshot) else { return }
        let time = now
        if time - attachedAt >= Self.settleSeconds { statistics.add(rate.total) }
        onSample?(Sample(
            time: time,
            gigabytesPerSecond: rate.total,
            perThread: rate.perThread,
            statistics: statistics,
            totalBytes: snapshot.totalBytes,
            config: engine.config
        ))
    }
}
