import CCPUBench
import Foundation

/// The tests. Each keeps its data in L1, so it measures the core rather than memory.
enum CPUWorkload: Int, CaseIterable, Sendable {
    case integer, branch, float, vector, crypto

    var name: String {
        switch self {
        case .integer: "Integer"
        case .branch: "Branches"
        case .float: "Floating point"
        case .vector: "Vector"
        case .crypto: "Crypto"
        }
    }

    var detail: String {
        switch self {
        case .integer: "SHA-256 in plain C"
        case .branch: "Quicksort of random integers"
        case .float: "Mandelbrot in scalar doubles"
        case .vector: "NEON matrix multiply, 32-bit floats"
        case .crypto: "AES-128 with the AES instructions"
        }
    }

    var unit: String {
        switch self {
        case .integer: "MB/s"
        case .branch: "M keys/s"
        case .float: "M iter/s"
        case .vector: "GFLOPS"
        case .crypto: "GB/s"
        }
    }

    /// Work units (bytes, keys, iterations, operations) per displayed unit.
    var unitScale: Double {
        switch self {
        case .integer, .branch, .float: 1e6
        case .vector, .crypto: 1e9
        }
    }
}

/// Where a test runs. macOS can't pin threads, so the core type is a request
/// made through the thread's quality of service.
enum CPURunMode: Int, CaseIterable, Sendable {
    case performanceCore, efficiencyCore, allCores

    func threads(_ info: CPUInfo) -> Int {
        self == .allCores ? max(1, info.cores.count) : 1
    }

    func title(_ info: CPUInfo) -> String {
        switch self {
        case .performanceCore: "1 P-core"
        case .efficiencyCore: "1 E-core"
        case .allCores: "All \(info.cores.count) cores"
        }
    }

    /// A Mac without E-cores has nothing to run that column on.
    static func available(_ info: CPUInfo) -> [CPURunMode] {
        allCases.filter { $0 != .efficiencyCore || !info.cores(.efficiency).isEmpty }
    }
}

struct CPUBenchCell: Hashable, Sendable {
    var workload: CPUWorkload
    var mode: CPURunMode
}

/// A running test: a thread-safe wrapper over the C workers.
final class CPUBenchEngine {
    private let lock = NSLock()
    private var engine: OpaquePointer?

    init?(workload: CPUWorkload, mode: CPURunMode, threads: Int) {
        let config = cb_config(
            work: Int32(workload.rawValue),
            cores: mode == .efficiencyCore ? CB_CORES_EFFICIENCY : CB_CORES_PERFORMANCE,
            threads: Int32(threads)
        )
        guard let started = cb_start(config) else { return nil }
        engine = started
    }

    deinit { stop() }

    /// Cumulative work units and the time they were read.
    func snapshot() -> (units: UInt64, nanoseconds: UInt64)? {
        lock.lock()
        defer { lock.unlock() }
        guard let engine else { return nil }
        return (cb_snapshot(engine, nil, 0), clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
    }

    func stop() {
        lock.lock()
        let current = engine
        engine = nil
        lock.unlock()
        if let current { cb_stop(current) }
    }
}

/// Runs every test in every mode, one at a time, off the main thread.
final class CPUSuiteRunner {
    struct Timing {
        /// Lets the clock ramp up before anything is counted.
        var warmupSeconds = 0.3
        var measureSeconds = 1.2
        var stepSeconds = 0.1
    }

    enum Event {
        /// A test began.
        case started(CPUBenchCell)
        /// A reading so far for the running test, in work units per second.
        case live(CPUBenchCell, Double)
        case measured(CPUBenchCell, Double)
        case finished(cancelled: Bool)
    }

    let cells: [CPUBenchCell]
    private let info: CPUInfo
    private let timing: Timing
    private let queue = DispatchQueue(label: "cpubench.suite", qos: .userInitiated)
    private let lock = NSLock()
    private var cancelled = false

    init(info: CPUInfo = .current, timing: Timing = Timing()) {
        self.info = info
        self.timing = timing
        // Mode by mode, so each mode's power reading covers one unbroken stretch.
        cells = CPURunMode.available(info).flatMap { mode in CPUWorkload.allCases.map { CPUBenchCell(workload: $0, mode: mode) } }
    }

    var estimatedSeconds: Double { Double(cells.count) * (timing.warmupSeconds + timing.measureSeconds) }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    /// Events arrive on the main queue, ending with `.finished`.
    func start(_ handler: @escaping (Event) -> Void) {
        queue.async { [self] in
            func send(_ event: Event) { DispatchQueue.main.async { handler(event) } }
            for cell in cells where !isCancelled {
                send(.started(cell))
                if let rate = measure(cell, live: { send(.live(cell, $0)) }) { send(.measured(cell, rate)) }
            }
            send(.finished(cancelled: isCancelled))
        }
    }

    private func measure(_ cell: CPUBenchCell, live: (Double) -> Void) -> Double? {
        guard let engine = CPUBenchEngine(workload: cell.workload, mode: cell.mode, threads: cell.mode.threads(info)) else { return nil }
        defer { engine.stop() }
        guard sleep(timing.warmupSeconds), let first = engine.snapshot() else { return nil }
        var rate: Double?
        let steps = max(1, Int((timing.measureSeconds / timing.stepSeconds).rounded()))
        for _ in 0..<steps {
            guard sleep(timing.stepSeconds), let now = engine.snapshot(), now.nanoseconds > first.nanoseconds else { return nil }
            // Always from the first reading, so the result is the mean of the whole window.
            let current = Double(now.units - first.units) / (Double(now.nanoseconds - first.nanoseconds) / 1e9)
            rate = current
            live(current)
        }
        return rate
    }

    /// False if cancelled meanwhile.
    private func sleep(_ seconds: Double) -> Bool {
        Thread.sleep(forTimeInterval: seconds)
        return !isCancelled
    }
}
