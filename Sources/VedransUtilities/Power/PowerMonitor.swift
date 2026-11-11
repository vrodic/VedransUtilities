import CPowerProbes
import Foundation
import IOKit

/// One reading of the machine's power, in watts.
///
/// Sources were chosen by testing, since Apple documents none of them:
///   PSTR  system total. Tracks every load.
///   PDTR  power arriving from the adapter.
///   PSVR  SoC rail. Rises with both CPU and GPU load, so GPU isn't added to it.
///   PMVC  memory rail. Stays flat on cache-only load and rises with DRAM traffic.
/// `soc + memory + other == system`, with `other` the remainder (display, storage...).
/// `gpu` comes from IOReport and is a separate reading, not part of that sum.
struct PowerSample {
    var time: TimeInterval
    var system: Double?
    var adapter: Double?
    var soc: Double?
    var memory: Double?
    var other: Double?
    var gpu: Double?
    /// CPU power used by this app, which during a benchmark is essentially the workers.
    var thisAppCPU: Double?
}

struct BatteryStatus {
    var chargePercent: Int
    var isCharging: Bool
    var isExternalPowerConnected: Bool
    var isFullyCharged: Bool
    var cycleCount: Int
    var healthPercent: Int?
    var voltage: Double
    /// Positive when charging, negative when discharging.
    var flowWatts: Double
    var minutesRemaining: Int?
    var temperatureCelsius: Double?
    var adapterRatedWatts: Int?
    var adapterVoltage: Double?
}

/// Peak and mean of one reading over the session.
struct PowerChannelStats {
    private(set) var peak = 0.0
    private(set) var mean = 0.0
    private var count = 0

    mutating func add(_ value: Double?) {
        guard let value else { return }
        count += 1
        mean += (value - mean) / Double(count)
        peak = max(peak, value)
    }
}

extension Notification.Name {
    /// Posted on the main queue with the new `PowerSample` as the object.
    static let powerSample = Notification.Name("PowerMonitor.sample")
}

final class PowerMonitor {
    static let shared = PowerMonitor()
    private static let interval = 0.5
    private static let batteryInterval = 5.0

    var onBattery: ((BatteryStatus?) -> Void)?

    private(set) var latest: PowerSample?
    private(set) var battery: BatteryStatus?
    private(set) var history: [PowerSample] = []
    private(set) var energyWattHours = 0.0
    private(set) var systemStats = PowerChannelStats()
    private(set) var socStats = PowerChannelStats()
    private(set) var memoryStats = PowerChannelStats()
    private(set) var otherStats = PowerChannelStats()
    private(set) var gpuStats = PowerChannelStats()
    private static let historyLimit = 1200

    private let queue = DispatchQueue(label: "power.monitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var warmupPolls = 3
    private var hasSMC = false
    private var hasGPU = false
    private var lastGPU: (energy: Int64, time: TimeInterval)?
    private var lastSelf: (energy: UInt64, time: TimeInterval)?
    private var lastBatteryRead: TimeInterval = -.infinity
    private let start = ProcessInfo.processInfo.systemUptime

    func begin() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.poll() }
        queue.async { [weak self] in
            self?.hasSMC = pp_smc_open()
            self?.hasGPU = pp_gpu_energy_open()
        }
        self.timer = timer
        timer.resume()
    }

    private func poll() {
        let time = ProcessInfo.processInfo.systemUptime - start
        var sample = PowerSample(time: time)
        // Some rails read near zero until they've been polled for a moment, which
        // would otherwise show up as a false spike in the remainder.
        warmupPolls -= 1
        if hasSMC, warmupPolls < 0 {
            sample.system = Self.smc("PSTR")
            sample.adapter = Self.smc("PDTR")
            sample.soc = Self.smc("PSVR")
            sample.memory = Self.smc("PMVC")
            if let system = sample.system, let soc = sample.soc, let memory = sample.memory {
                // Rails are sampled at slightly different moments, so this can dip below 0.
                sample.other = max(0, system - soc - memory)
            }
        }
        if hasGPU {
            var energy: Int64 = 0
            if pp_gpu_energy_read(&energy) {
                if let last = lastGPU, time > last.time {
                    sample.gpu = Double(energy - last.energy) / 1e9 / (time - last.time)
                }
                lastGPU = (energy, time)
            }
        }
        var selfEnergy: UInt64 = 0
        if pp_self_cpu_energy(&selfEnergy) {
            if let last = lastSelf, time > last.time, selfEnergy >= last.energy {
                sample.thisAppCPU = Double(selfEnergy - last.energy) / 1e9 / (time - last.time)
            }
            lastSelf = (selfEnergy, time)
        }

        var newBattery: BatteryStatus??
        if time - lastBatteryRead >= Self.batteryInterval {
            lastBatteryRead = time
            newBattery = .some(Self.readBattery())
        }

        DispatchQueue.main.async { [self] in
            if let newBattery {
                battery = newBattery
                onBattery?(newBattery)
            }
            if let system = sample.system, let last = latest?.time {
                energyWattHours += system * (sample.time - last) / 3600
            }
            systemStats.add(sample.system)
            socStats.add(sample.soc)
            memoryStats.add(sample.memory)
            otherStats.add(sample.other)
            gpuStats.add(sample.gpu)
            latest = sample
            history.append(sample)
            if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
            NotificationCenter.default.post(name: .powerSample, object: sample)
        }
    }

    private static func smc(_ key: String) -> Double? {
        var value: Float = 0
        return pp_smc_read_float(key, &value) ? Double(value) : nil
    }

    private static func readBattery() -> BatteryStatus? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        return parseBattery(properties, temperature: smc("TB0T"))
    }

    static func parseBattery(_ properties: [String: Any], temperature: Double?) -> BatteryStatus? {
        guard let charge = properties["CurrentCapacity"] as? Int else { return nil }
        let millivolts = properties["Voltage"] as? Int ?? 0
        // Reported as an unsigned 64-bit value in some OS versions, so negatives can wrap.
        let milliamps = (properties["InstantAmperage"] as? NSNumber)?.int64Value
            ?? (properties["Amperage"] as? NSNumber)?.int64Value ?? 0
        let details = properties["BatteryData"] as? [String: Any]
        var health: Int?
        if let design = details?["DesignCapacity"] as? Int, design > 0,
           let nominal = details?["NominalChargeCapacity"] as? Int {
            health = min(100, nominal * 100 / design)
        }
        let remaining = properties["TimeRemaining"] as? Int ?? 65535
        let adapter = properties["AdapterDetails"] as? [String: Any]
        let external = properties["ExternalConnected"] as? Bool ?? false
        return BatteryStatus(
            chargePercent: charge,
            isCharging: properties["IsCharging"] as? Bool ?? false,
            isExternalPowerConnected: external,
            isFullyCharged: properties["FullyCharged"] as? Bool ?? false,
            cycleCount: properties["CycleCount"] as? Int ?? 0,
            healthPercent: health,
            voltage: Double(millivolts) / 1000,
            flowWatts: Double(millivolts) * Double(milliamps) / 1_000_000,
            minutesRemaining: remaining > 0 && remaining < 65535 ? remaining : nil,
            temperatureCelsius: temperature,
            adapterRatedWatts: external ? adapter?["Watts"] as? Int : nil,
            adapterVoltage: external ? (adapter?["AdapterVoltage"] as? Int).map { Double($0) / 1000 } : nil
        )
    }
}
