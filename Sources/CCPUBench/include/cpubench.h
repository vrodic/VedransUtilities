#ifndef CPUBENCH_H
#define CPUBENCH_H

#include <stddef.h>
#include <stdint.h>

#define CB_WORK_INTEGER 0
#define CB_WORK_BRANCH 1
#define CB_WORK_FLOAT 2
#define CB_WORK_VECTOR 3
#define CB_WORK_CRYPTO 4
#define CB_WORK_COUNT 5

#define CB_CORES_PERFORMANCE 0
#define CB_CORES_EFFICIENCY 1

/// Side of the square matrices the vector test multiplies.
#define CB_MATRIX_SIDE 32
/// Floating-point operations in one multiply: a multiply and an add per term.
#define CB_MATRIX_FLOPS (2u * CB_MATRIX_SIDE * CB_MATRIX_SIDE * CB_MATRIX_SIDE)

typedef struct {
    int32_t work;
    int32_t cores;
    int32_t threads;
} cb_config;

typedef struct cb_engine cb_engine;

/// Starts workers, which begin at once. Every test's data fits in L1, so the
/// result describes the core and not the memory behind it. NULL on failure.
cb_engine *cb_start(cb_config config);

/// Writes per-thread cumulative work and returns the total. The unit depends on
/// the test: bytes, keys, iterations or floating-point operations. Thread safe
/// against the workers, but must not race cb_stop.
uint64_t cb_snapshot(const cb_engine *engine, uint64_t *per_thread, int32_t capacity);

/// Stops and joins the workers and frees everything.
void cb_stop(cb_engine *engine);

// Kernels, exposed for tests.

/// SHA-256 in portable C, without the SHA instructions.
void cb_sha256(const uint8_t *data, size_t bytes, uint8_t digest[32]);
/// In-place quicksort, ascending.
void cb_sort(uint32_t *values, size_t count);
/// Escape-time iterations summed over a `side` x `side` grid of scalar doubles.
uint64_t cb_mandelbrot(double x0, double y0, double step, int32_t side, int32_t max_iterations);
/// c = a * b for CB_MATRIX_SIDE-square row-major matrices, in NEON.
void cb_matmul(float *c, const float *a, const float *b);
/// AES-128 key schedule: 11 round keys.
void cb_aes128_expand(const uint8_t key[16], uint8_t round_keys[176]);
/// AES-128 on whole 16-byte blocks in place (ECB), using the AES instructions.
void cb_aes128_encrypt(const uint8_t round_keys[176], uint8_t *data, size_t bytes);

#endif
