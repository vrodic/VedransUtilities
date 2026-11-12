import Foundation
import IOKit

/// What macOS and the device tree say about the processor. Read once.
struct CPUInfo {
    enum CoreKind: Hashable {
        case performance, efficiency

        var title: String { self == .performance ? "Performance" : "Efficiency" }
        var letter: String { self == .performance ? "P" : "E" }
    }

    struct Core: Equatable {
        /// The logical CPU number macOS uses.
        var id: Int
        var kind: CoreKind
        var cluster: Int
        /// Apple's name for the core design, such as Everest.
        var design: String?
    }

    struct FrequencyState: Equatable {
        var megahertz: Double
        var millivolts: Int
    }

    struct Caches {
        var l1Instruction: UInt64
        var l1Data: UInt64
        var l2: UInt64
        var coresPerL2: Int
    }

    struct Feature: Equatable {
        var name: String
        var isSupported: Bool
    }

    var chipName: String
    var modelIdentifier: String
    /// Apple's chip number, such as t6041.
    var platform: String?
    var generation: String?
    var revision: String?
    var cores: [Core]
    var states: [CoreKind: [FrequencyState]]
    var caches: [CoreKind: Caches]
    var features: [Feature]
    var memoryBytes: UInt64
    var pageBytes: UInt64
    var cacheLineBytes: UInt64
    var timebaseHertz: UInt64
    var streamingVectorBits: Int?

    static let current = read()

    func cores(_ kind: CoreKind) -> [Core] { cores.filter { $0.kind == kind } }

    func maxMegahertz(_ kind: CoreKind) -> Double? { states[kind]?.map(\.megahertz).max() }

    func design(_ kind: CoreKind) -> String? { cores(kind).compactMap(\.design).first }

    /// Core counts per cluster in cluster order, for example "4 E + 5 P + 5 P".
    var clusterSummary: String {
        var groups: [(cluster: Int, kind: CoreKind, count: Int)] = []
        for core in cores {
            if let index = groups.firstIndex(where: { $0.cluster == core.cluster }) {
                groups[index].count += 1
            } else {
                groups.append((core.cluster, core.kind, 1))
            }
        }
        return groups.sorted { $0.cluster < $1.cluster }.map { "\($0.count) \($0.kind.letter)" }.joined(separator: " + ")
    }

    // MARK: Reading

    private static func read() -> CPUInfo {
        let armIO = DeviceTree.entry("/arm-io")
        let powerManager = DeviceTree.child(of: armIO, named: "pmgr")
        defer {
            IOObjectRelease(armIO)
            IOObjectRelease(powerManager)
        }
        var states: [CoreKind: [FrequencyState]] = [:]
        // Apple's convention since the M1: table 1 is the E-cores, table 5 the P-cores.
        for (kind, key) in [(CoreKind.efficiency, "voltage-states1-sram"), (.performance, "voltage-states5-sram")] {
            if let data = DeviceTree.property(powerManager, key) as? Data {
                let table = parseFrequencyStates(data)
                if !table.isEmpty { states[kind] = table }
            }
        }

        var caches: [CoreKind: Caches] = [:]
        for (level, kind) in [(0, CoreKind.performance), (1, .efficiency)] {
            let prefix = "hw.perflevel\(level)"
            guard let count = Sysctl.value("\(prefix).logicalcpu"), count > 0 else { continue }
            caches[kind] = Caches(
                l1Instruction: Sysctl.value("\(prefix).l1icachesize") ?? 0,
                l1Data: Sysctl.value("\(prefix).l1dcachesize") ?? 0,
                l2: Sysctl.value("\(prefix).l2cachesize") ?? 0,
                coresPerL2: Int(Sysctl.value("\(prefix).cpusperl2") ?? 1)
            )
        }

        let hasSME = Sysctl.value("hw.optional.arm.FEAT_SME") == 1
        return CPUInfo(
            chipName: Sysctl.string("machdep.cpu.brand_string") ?? "Apple Silicon",
            modelIdentifier: Sysctl.string("hw.model") ?? "",
            platform: (DeviceTree.property(armIO, "compatible") as? Data).flatMap(parsePlatform),
            generation: (DeviceTree.property(armIO, "soc-generation") as? Data)?.strings.first,
            revision: (DeviceTree.property(armIO, "chip-revision") as? Data)?.uint32.map(revisionName),
            cores: readCores(),
            states: states,
            caches: caches,
            features: readFeatures(),
            memoryBytes: Sysctl.value("hw.memsize") ?? 0,
            pageBytes: Sysctl.value("hw.pagesize") ?? 0,
            cacheLineBytes: Sysctl.value("hw.cachelinesize") ?? 0,
            timebaseHertz: Sysctl.value("hw.tbfrequency") ?? 0,
            streamingVectorBits: hasSME ? Sysctl.value("hw.optional.arm.sme_max_svl_b").map { Int($0) * 8 } : nil
        )
    }

    private static func readCores() -> [Core] {
        let parent = DeviceTree.entry("/cpus")
        defer { IOObjectRelease(parent) }
        var cores: [Core] = []
        for child in DeviceTree.children(of: parent) {
            defer { IOObjectRelease(child) }
            guard let id = DeviceTree.property(child, "logical-cpu-id") as? Int,
                  let type = (DeviceTree.property(child, "cluster-type") as? Data)?.strings.first else { continue }
            let cluster = DeviceTree.property(child, "logical-cluster-id") as? Int
                ?? (DeviceTree.property(child, "cluster-id") as? Data)?.uint32.map(Int.init) ?? 0
            let design = (DeviceTree.property(child, "compatible") as? Data)?.strings.first.flatMap(designName)
            cores.append(Core(id: id, kind: type == "E" ? .efficiency : .performance, cluster: cluster, design: design))
        }
        if !cores.isEmpty { return cores.sorted { $0.id < $1.id } }

        // No device tree, as in a virtual machine: macOS numbers E-cores first.
        let efficiency = Int(Sysctl.value("hw.perflevel1.logicalcpu") ?? 0)
        let total = Int(Sysctl.value("hw.logicalcpu") ?? 1)
        return (0..<total).map { Core(id: $0, kind: $0 < efficiency ? .efficiency : .performance, cluster: $0 < efficiency ? 0 : 1, design: nil) }
    }

    /// Every flag under hw.optional.arm, so features newer than this app still show up.
    private static func readFeatures() -> [Feature] {
        let prefix = "hw.optional.arm."
        var features: [Feature] = []
        for name in Sysctl.names(under: "hw.optional") where name.hasPrefix(prefix) {
            let short = String(name.dropFirst(prefix.count))
            // Flags are 0 or 1; the others (caps, sme_max_svl_b) are values, not features.
            guard short.first?.isUppercase == true, let value = Sysctl.value(name), value <= 1 else { continue }
            features.append(Feature(name: short.hasPrefix("FEAT_") ? String(short.dropFirst(5)) : short, isSupported: value == 1))
        }
        return features.sorted { ($0.isSupported ? 0 : 1, $0.name.lowercased()) < ($1.isSupported ? 0 : 1, $1.name.lowercased()) }
    }

    // MARK: Parsing

    /// Pairs of little-endian 32-bit words: frequency, then voltage in millivolts.
    /// Frequency is in hertz up to the M3 and kilohertz from the M4.
    static func parseFrequencyStates(_ data: Data) -> [FrequencyState] {
        let words = data.uint32s
        return stride(from: 0, to: words.count - 1, by: 2).compactMap { index in
            let raw = Double(words[index])
            guard raw > 0 else { return nil }
            return FrequencyState(megahertz: raw >= 100_000_000 ? raw / 1e6 : raw / 1e3, millivolts: Int(words[index + 1]))
        }
    }

    /// "arm-io,t6041" gives "t6041".
    static func parsePlatform(_ compatible: Data) -> String? {
        compatible.strings.first.flatMap { $0.split(separator: ",").last }.map(String.init)
    }

    /// 0x11 gives "B1": the high nibble is the stepping letter.
    static func revisionName(_ raw: UInt32) -> String {
        let letter = Character(UnicodeScalar(UInt8(65 + min(25, (raw >> 4) & 0xF))))
        return "\(letter)\(raw & 0xF)"
    }

    /// "apple,everest" gives "Everest".
    static func designName(_ compatible: String) -> String? {
        guard compatible.hasPrefix("apple,") else { return nil }
        return compatible.dropFirst(6).capitalized
    }
}

extension Sysctl {
    /// Names of every value below `root`, found by walking the kernel's tree.
    static func names(under root: String) -> [String] {
        var oid = [Int32](repeating: 0, count: Int(CTL_MAXNAME))
        var length = oid.count
        guard sysctlnametomib(root, &oid, &length) == 0 else { return [] }
        var current = Array(oid[0..<length])
        var names: [String] = []
        // The undocumented {0, 2} and {0, 1} queries are what sysctl(8) itself uses.
        while names.count < 4096 {
            var query: [Int32] = [0, 2] + current
            var next = [Int32](repeating: 0, count: Int(CTL_MAXNAME))
            var nextSize = next.count * MemoryLayout<Int32>.size
            guard sysctl(&query, UInt32(query.count), &next, &nextSize, nil, 0) == 0 else { break }
            current = Array(next[0..<nextSize / MemoryLayout<Int32>.size])

            query = [0, 1] + current
            var buffer = [CChar](repeating: 0, count: 256)
            var size = buffer.count
            guard sysctl(&query, UInt32(query.count), &buffer, &size, nil, 0) == 0 else { break }
            let name = String(cString: buffer)
            guard name.hasPrefix(root + ".") else { break }
            names.append(name)
        }
        return names
    }
}

/// Read-only access to the firmware device tree in the IORegistry.
enum DeviceTree {
    /// The caller releases the result. Zero if the path doesn't exist.
    static func entry(_ path: String) -> io_registry_entry_t {
        IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:\(path)")
    }

    /// The caller releases each child.
    static func children(of entry: io_registry_entry_t) -> [io_registry_entry_t] {
        guard entry != 0 else { return [] }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [io_registry_entry_t] = []
        while case let child = IOIteratorNext(iterator), child != 0 { result.append(child) }
        return result
    }

    /// The caller releases the result. Zero if there's no such child.
    static func child(of entry: io_registry_entry_t, named name: String) -> io_registry_entry_t {
        var found: io_registry_entry_t = 0
        for child in children(of: entry) {
            var buffer = [CChar](repeating: 0, count: 128)
            if found == 0, IORegistryEntryGetNameInPlane(child, kIODeviceTreePlane, &buffer) == KERN_SUCCESS, String(cString: buffer) == name {
                found = child
            } else {
                IOObjectRelease(child)
            }
        }
        return found
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        guard entry != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

extension Data {
    /// Device-tree strings are NUL-terminated and may be several in a row.
    var strings: [String] {
        split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
    }

    var uint32s: [UInt32] {
        stride(from: 0, to: count - 3, by: 4).map { offset in
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * UInt32($1)) }
        }
    }

    var uint32: UInt32? { uint32s.first }
}
