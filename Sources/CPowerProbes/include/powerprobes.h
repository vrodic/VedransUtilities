#ifndef POWERPROBES_H
#define POWERPROBES_H

#include <stdbool.h>
#include <stdint.h>

/// Opens the AppleSMC user client. Safe to call repeatedly. No privileges needed.
bool pp_smc_open(void);
/// Reads a 4-character SMC key holding a 32-bit float. False if absent or another type.
bool pp_smc_read_float(const char *key, float *out);

/// Subscribes to the IOReport "Energy Model" group through the private
/// libIOReport, loaded at runtime. False if unavailable.
bool pp_gpu_energy_open(void);
/// Cumulative GPU energy in nanojoules. Only meaningful as a difference.
bool pp_gpu_energy_read(int64_t *nanojoules);

#define PP_CORE_NAME_BYTES 16
#define PP_MAX_CORE_STATES 32

/// Subscribes to IOReport's per-core performance-state residencies. False if unavailable.
bool pp_cpu_states_open(void);
/// Reads cumulative time per core, only meaningful as a difference. Arrays are
/// flat with `capacity` entries: names of PP_CORE_NAME_BYTES each (ECPU.., PCPU..),
/// the number of running states, time not running, and PP_MAX_CORE_STATES
/// residencies per core, slowest state first. Returns the number of cores written.
int32_t pp_cpu_states_read(char *names, int32_t *state_counts, uint64_t *idle, uint64_t *residency, int32_t capacity);

/// Cumulative CPU energy this process has used, in nanojoules.
bool pp_self_cpu_energy(uint64_t *nanojoules);

#endif
