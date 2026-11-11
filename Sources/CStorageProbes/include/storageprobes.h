#ifndef STORAGEPROBES_H
#define STORAGEPROBES_H

#include <stdbool.h>
#include <stdint.h>

/// One NVMe drive and its SMART / Health Information log (NVMe spec, log page 2).
/// 128-bit counters are reduced to their low 64 bits, which no real drive exceeds.
typedef struct {
    char model[48];
    char firmware[16];
    char bsd_name[32];
    uint64_t capacity_bytes;
    bool is_internal;
    /// False when the drive is listed but its log couldn't be read.
    bool has_smart;

    uint8_t critical_warning;
    uint16_t temperature_kelvin;
    uint8_t available_spare;
    uint8_t available_spare_threshold;
    uint8_t percentage_used;
    /// In units of 1000 512-byte blocks, as the spec defines them.
    uint64_t data_units_read;
    uint64_t data_units_written;
    uint64_t host_read_commands;
    uint64_t host_write_commands;
    uint64_t controller_busy_minutes;
    uint64_t power_cycles;
    uint64_t power_on_hours;
    uint64_t unsafe_shutdowns;
    uint64_t media_errors;
    uint64_t error_log_entries;
} sp_drive;

/// Reads every NVMe drive macOS exposes SMART for. No privileges needed.
/// Returns how many drives were written to `drives`.
int32_t sp_read_drives(sp_drive *drives, int32_t capacity);

#endif
