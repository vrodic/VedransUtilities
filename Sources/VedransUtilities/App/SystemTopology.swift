import Foundation

struct SystemTopology {
    enum MemoryLevel: Int, CaseIterable {
        case l1, l2, memory

        var name: String {
            switch self {
            case .l1: "L1"
            case .l2: "L2"
            case .memory: "SLC / DRAM"
            }
        }
    }

    struct Cluster {
        var cores: Int
        var l1Bytes: UInt64
        var l2Bytes: UInt64
        var coresPerL2: Int
    }

    var chipName: String
    var memoryBytes: UInt64
    var logicalCPUs: Int
    var performance: Cluster
    var efficiency: Cluster

    static let current = SystemTopology(
        chipName: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
        memoryBytes: sysctlValue("hw.memsize") ?? 0,
        logicalCPUs: Int(sysctlValue("hw.ncpu") ?? 1),
        performance: readCluster(0),
        efficiency: readCluster(1)
    )

    /// The cores behind a CPU choice; the GPU's caches aren't published.
    func cluster(for processor: Processor) -> Cluster? {
        switch processor {
        case .performance: performance
        case .efficiency: efficiency
        case .gpu: nil
        }
    }

    /// One thread per core of the chosen type. Going further would mix core types
    /// (or share cores), and the result would no longer describe the choice.
    /// The GPU schedules its own threads, so it counts as a single worker.
    func maxThreads(for processor: Processor) -> Int {
        max(1, cluster(for: processor)?.cores ?? 1)
    }

    /// Where a configuration's data mostly lives. An estimate: L2 is shared within
    /// a cluster, and macOS decides which cluster each thread runs on.
    func level(for config: BenchmarkConfig) -> MemoryLevel {
        guard let cluster = cluster(for: config.processor) else { return .memory }
        let perThread = config.blockBytes * UInt64(config.operation.bufferCount)
        if perThread <= cluster.l1Bytes { return .l1 }
        let sharers = UInt64(max(1, min(config.threads, cluster.coresPerL2)))
        if perThread * sharers <= cluster.l2Bytes { return .l2 }
        return .memory
    }

    private static func readCluster(_ level: Int) -> Cluster {
        let prefix = "hw.perflevel\(level)"
        return Cluster(
            cores: Int(sysctlValue("\(prefix).logicalcpu") ?? 0),
            l1Bytes: sysctlValue("\(prefix).l1dcachesize") ?? 0,
            l2Bytes: sysctlValue("\(prefix).l2cachesize") ?? 0,
            coresPerL2: Int(sysctlValue("\(prefix).cpusperl2") ?? 1)
        )
    }

    private static func sysctlValue(_ name: String) -> UInt64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size <= 8 else { return nil }
        var value: UInt64 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

enum Format {
    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
        var scaled = Double(value)
        var index = 0
        while scaled >= 1024, index < units.count - 1 {
            scaled /= 1024
            index += 1
        }
        let isWhole = scaled == scaled.rounded()
        return String(format: isWhole || scaled >= 100 ? "%.0f %@" : "%.1f %@", scaled, units[index])
    }

    /// Decimal data volume, consistent with GB/s.
    static func volume(_ value: UInt64) -> String {
        let number = Double(value)
        if number >= 1e15 { return String(format: "%.2f PB", number / 1e15) }
        if number >= 1e12 { return String(format: "%.2f TB", number / 1e12) }
        return String(format: "%.1f GB", number / 1e9)
    }

    /// Three significant figures, so live values don't shimmer in their low digits.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let size = abs(value)
        if size >= 100 { return String(format: "%.0f", value) }
        if size >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    static func rate(_ gigabytesPerSecond: Double) -> String { "\(number(gigabytesPerSecond)) GB/s" }

    static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: value >= 100 ? "%.0f W" : "%.1f W", value)
    }

    static func duration(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}
