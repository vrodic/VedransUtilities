#ifndef MEMBENCH_H
#define MEMBENCH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define MB_OP_READ 0
#define MB_OP_WRITE 1
#define MB_OP_COPY 2
#define MB_OP_TRIAD 3
#define MB_OP_RANDOM 4

#define MB_CORES_PERFORMANCE 0
#define MB_CORES_EFFICIENCY 1

/// Bytes the random kernel counts per access: one Apple Silicon cache line.
#define MB_RANDOM_LINE_BYTES 128

typedef struct {
    int32_t op;
    int32_t cores;
    int32_t threads;
    /// Per-thread, per-buffer working set. Rounded down to a power of two.
    uint64_t block_bytes;
} mb_config;

typedef struct mb_engine mb_engine;

/// Spawns workers, which allocate and fault in their own buffers, then begin
/// together once all are ready. Returns immediately; NULL if threads can't start.
mb_engine *mb_start(mb_config config);

/// Blocks until all workers are running. False if any buffer allocation failed.
bool mb_wait_ready(mb_engine *engine);

/// Writes per-thread cumulative byte counts; returns their total. Thread safe
/// against the workers, but must not race mb_stop.
uint64_t mb_snapshot(const mb_engine *engine, uint64_t *per_thread, int32_t capacity);

/// Stops and joins workers and frees everything. Can take a moment for big buffers.
void mb_stop(mb_engine *engine);

/// How many separate buffers each worker uses for an operation.
int32_t mb_buffers_for_op(int32_t op);

// Kernels, exposed for tests. `bytes` is rounded down to the kernel's unit.
void mb_kernel_read(const void *src, size_t bytes);
void mb_kernel_write(void *dst, size_t bytes, uint8_t value);
void mb_kernel_copy(void *dst, const void *src, size_t bytes);
/// a[i] = b[i] + scalar * c[i], on doubles.
void mb_kernel_triad(double *a, const double *b, const double *c, size_t bytes, double scalar);
/// Independent loads at pseudo-random line offsets. `block` must be a power of two.
/// Returns the updated generator state.
uint64_t mb_kernel_random(const void *base, uint64_t block, size_t accesses, uint64_t state);

#endif
