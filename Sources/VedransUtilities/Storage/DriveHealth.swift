import CStorageProbes
import Foundation

/// One drive's SMART health, in plain units.
struct DriveHealth: Equatable {
    enum Status: Int, Comparable {
        case good, warning, critical

        var title: String {
            switch self {
            case .good: "Healthy"
            case .warning: "Needs attention"
            case .critical: "Failing"
            }
        }

        static func < (lhs: Status, rhs: Status) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Check: Equatable {
        var title: String
        var detail: String
        var status: Status
    }

    /// NVMe "data units" are 1000 blocks of 512 bytes.
    static let dataUnitBytes: UInt64 = 512_000

    var model: String
    var firmware: String
    var bsdName: String
    var capacityBytes: UInt64
    var isInternal: Bool
    var hasSMART: Bool

    var criticalWarning: UInt8
    var temperatureCelsius: Double?
    var availableSpare: Int
    var spareThreshold: Int
    var percentageUsed: Int
    var bytesRead: UInt64
    var bytesWritten: UInt64
    var hostReadCommands: UInt64
    var hostWriteCommands: UInt64
    var controllerBusyMinutes: UInt64
    var powerCycles: UInt64
    var powerOnHours: UInt64
    var unsafeShutdowns: UInt64
    var mediaErrors: UInt64
    var errorLogEntries: UInt64

    init(_ raw: sp_drive) {
        var copy = raw
        model = Self.string(&copy.model)
        firmware = Self.string(&copy.firmware)
        bsdName = Self.string(&copy.bsd_name)
        capacityBytes = raw.capacity_bytes
        isInternal = raw.is_internal
        hasSMART = raw.has_smart
        criticalWarning = raw.critical_warning
        temperatureCelsius = raw.temperature_kelvin > 0 ? Double(raw.temperature_kelvin) - 273.15 : nil
        availableSpare = Int(raw.available_spare)
        spareThreshold = Int(raw.available_spare_threshold)
        percentageUsed = Int(raw.percentage_used)
        bytesRead = raw.data_units_read.multipliedReportingOverflow(by: Self.dataUnitBytes).partialValue
        bytesWritten = raw.data_units_written.multipliedReportingOverflow(by: Self.dataUnitBytes).partialValue
        hostReadCommands = raw.host_read_commands
        hostWriteCommands = raw.host_write_commands
        controllerBusyMinutes = raw.controller_busy_minutes
        powerCycles = raw.power_cycles
        powerOnHours = raw.power_on_hours
        unsafeShutdowns = raw.unsafe_shutdowns
        mediaErrors = raw.media_errors
        errorLogEntries = raw.error_log_entries
    }

    private static func string<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static func readAll() -> [DriveHealth] {
        var raw = [sp_drive](repeating: sp_drive(), count: 16)
        let count = Int(sp_read_drives(&raw, Int32(raw.count)))
        return raw.prefix(count).map(DriveHealth.init)
    }

    /// The drive's own wear estimate, inverted. It can pass 100% used and keep working.
    var lifeRemainingPercent: Int { max(0, 100 - percentageUsed) }

    var name: String { model.isEmpty ? "Unknown drive" : model }

    /// Each critical-warning bit from the spec, plus the error counters worth acting on.
    var checks: [Check] {
        func bit(_ index: UInt8) -> Bool { criticalWarning & (1 << index) != 0 }
        return [
            Check(
                title: "Spare capacity",
                detail: bit(0) ? "Below the drive's threshold of \(spareThreshold)%" : "\(availableSpare)% left, threshold \(spareThreshold)%",
                status: bit(0) ? .critical : .good
            ),
            Check(
                title: "Temperature",
                detail: bit(1) ? "Outside the drive's safe range" : temperatureCelsius.map { String(format: "%.0f °C, within range", $0) } ?? "Within range",
                status: bit(1) ? .warning : .good
            ),
            Check(
                title: "Reliability",
                detail: bit(2) ? "Degraded by media or internal errors" : "Not degraded",
                status: bit(2) ? .critical : .good
            ),
            Check(
                title: "Writable",
                detail: bit(3) ? "The drive has gone read-only" : "Accepting writes",
                status: bit(3) ? .critical : .good
            ),
            Check(
                title: "Wear",
                detail: percentageUsed >= 100 ? "Past its rated endurance (\(percentageUsed)% used)" : "\(percentageUsed)% of rated endurance used",
                status: percentageUsed >= 100 ? .critical : percentageUsed >= 90 ? .warning : .good
            ),
            Check(
                title: "Media errors",
                detail: mediaErrors == 0 ? "None recorded" : "\(mediaErrors) unrecovered data errors",
                status: mediaErrors == 0 ? .good : .warning
            ),
        ]
    }

    var status: Status { hasSMART ? (checks.map(\.status).max() ?? .good) : .warning }
}

enum DriveFormat {
    /// Decimal, as drive makers and the NVMe spec count.
    static func bytes(_ value: UInt64) -> String {
        let number = Double(value)
        if number >= 1e15 { return String(format: "%.2f PB", number / 1e15) }
        if number >= 1e12 { return String(format: "%.1f TB", number / 1e12) }
        return String(format: "%.0f GB", number / 1e9)
    }

    static func count(_ value: UInt64) -> String {
        let number = Double(value)
        if number >= 1e9 { return String(format: "%.2f billion", number / 1e9) }
        if number >= 1e6 { return String(format: "%.1f million", number / 1e6) }
        return NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    static func hours(_ hours: UInt64) -> String {
        if hours >= 24 * 365 { return String(format: "%.1f years", Double(hours) / (24 * 365)) }
        if hours >= 48 { return "\(hours / 24) days" }
        return "\(hours) h"
    }
}
