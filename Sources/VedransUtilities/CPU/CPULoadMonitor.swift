import CPowerProbes
import Foundation

/// How busy one core was over a sampling window, and how fast it ran while busy.
struct CoreLoad: Equatable {
    /// Share of the window spent running, 0 to 1.
    var active: Double
    /// Time-weighted clock while running. Nil when idle or when macOS doesn't report it.
    var megahertz: Double?
}

/// Cumulative time one core has spent idle and in each performance state.
struct CoreResidency: Equatable {
    var name: String
    var idle: UInt64
    /// Slowest state first.
    var states: [UInt64]
}

/// Samples every core twice a second while something is listening.
///
/// The preferred source is IOReport's performance-state residencies, which give
/// both activity and clock speed. Without it, Mach's per-processor tick counts
/// still give activity.
final class CPULoadMonitor {
    private static let interval = 0.5

    /// Called on the main queue, one entry per core in `CPUInfo.cores` order.
    var onSample: (([CoreLoad]) -> Void)?

    private let info: CPUInfo
    private let queue = DispatchQueue(label: "cpu.load", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var hasStates = false
    private var lastResidency: [CoreResidency] = []
    private var lastTicks: [[UInt32]] = []

    init(info: CPUInfo = .current) {
        self.info = info
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.interval)
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        queue.async { [self] in
            lastResidency = []
            lastTicks = []
        }
    }

    private func poll() {
        if !hasStates { hasStates = pp_cpu_states_open() }
        var loads: [CoreLoad]?
        if hasStates {
            let now = Self.readResidency()
            loads = Self.loads(from: lastResidency, to: now, info: info)
            lastResidency = now
        }
        let ticks = Self.readTicks()
        if loads == nil { loads = Self.loads(fromTicks: lastTicks, to: ticks, coreCount: info.cores.count) }
        lastTicks = ticks
        guard let loads else { return }
        DispatchQueue.main.async { [weak self] in self?.onSample?(loads) }
    }

    // MARK: Sources

    private static func readResidency() -> [CoreResidency] {
        let capacity = 128
        var names = [CChar](repeating: 0, count: capacity * Int(PP_CORE_NAME_BYTES))
        var counts = [Int32](repeating: 0, count: capacity)
        var idle = [UInt64](repeating: 0, count: capacity)
        var residency = [UInt64](repeating: 0, count: capacity * Int(PP_MAX_CORE_STATES))
        let cores = Int(pp_cpu_states_read(&names, &counts, &idle, &residency, Int32(capacity)))
        return (0..<cores).map { core in
            let name = names.withUnsafeBufferPointer { String(cString: $0.baseAddress! + core * Int(PP_CORE_NAME_BYTES)) }
            let first = core * Int(PP_MAX_CORE_STATES)
            return CoreResidency(name: name, idle: idle[core], states: Array(residency[first..<first + Int(counts[core])]))
        }
    }

    /// User, system, idle and nice ticks per logical CPU.
    private static func readTicks() -> [[UInt32]] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(cpuCount)).map { cpu in (0..<states).map { UInt32(bitPattern: info[cpu * states + $0]) } }
    }

    // MARK: Arithmetic

    /// Pairs IOReport's channels with cores by type, in order. Nil when they
    /// don't line up, so a wrong pairing is never shown.
    static func loads(from previous: [CoreResidency], to current: [CoreResidency], info: CPUInfo) -> [CoreLoad]? {
        guard previous.count == current.count, current.count == info.cores.count else { return nil }
        var result = [CoreLoad?](repeating: nil, count: info.cores.count)
        for kind in [CPUInfo.CoreKind.efficiency, .performance] {
            let channels = current.indices.filter { current[$0].name.hasPrefix(kind.letter) }
            let cores = info.cores.indices.filter { info.cores[$0].kind == kind }
            guard channels.count == cores.count else { return nil }
            for (channel, core) in zip(channels, cores) {
                guard previous[channel].name == current[channel].name else { return nil }
                result[core] = load(from: previous[channel], to: current[channel], table: info.states[kind] ?? [])
            }
        }
        let loads = result.compactMap { $0 }
        return loads.count == info.cores.count ? loads : nil
    }

    static func load(from previous: CoreResidency, to current: CoreResidency, table: [CPUInfo.FrequencyState]) -> CoreLoad {
        guard previous.states.count == current.states.count else { return CoreLoad(active: 0) }
        let states = zip(current.states, previous.states).map { Double($0 &- $1) }
        let running = states.reduce(0, +)
        let total = running + Double(current.idle &- previous.idle)
        guard total > 0 else { return CoreLoad(active: 0) }
        var megahertz: Double?
        // Only trust the clock when the table has exactly one entry per state.
        if running > 0, table.count == states.count {
            megahertz = zip(states, table).reduce(0) { $0 + $1.0 * $1.1.megahertz } / running
        }
        return CoreLoad(active: running / total, megahertz: megahertz)
    }

    static func loads(fromTicks previous: [[UInt32]], to current: [[UInt32]], coreCount: Int) -> [CoreLoad]? {
        guard previous.count == current.count, current.count == coreCount else { return nil }
        return zip(current, previous).map { now, before in
            let delta = zip(now, before).map { Double($0 &- $1) }
            let total = delta.reduce(0, +)
            let idle = delta.indices.contains(Int(CPU_STATE_IDLE)) ? delta[Int(CPU_STATE_IDLE)] : 0
            return CoreLoad(active: total > 0 ? (total - idle) / total : 0)
        }
    }
}
