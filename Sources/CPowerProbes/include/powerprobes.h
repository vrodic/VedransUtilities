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

/// Cumulative CPU energy this process has used, in nanojoules.
bool pp_self_cpu_energy(uint64_t *nanojoules);

#endif
