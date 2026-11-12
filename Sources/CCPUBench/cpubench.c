#include "cpubench.h"

#include <arm_neon.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#if !defined(__aarch64__)
#error "VedransUtilities targets Apple Silicon."
#endif

#define CACHE_LINE 128
// Small enough to sit in every core's L1 with room to spare.
#define HASH_BYTES 4096u
#define SORT_KEYS 4096u
#define CIPHER_BYTES 4096u
#define GRID_SIDE 32
#define GRID_ITERATIONS 512
#define MATRIX_CELLS (CB_MATRIX_SIDE * CB_MATRIX_SIDE)
// Multiplies between counter updates, so the update costs nothing next to them.
#define MATRIX_BATCH 16

// MARK: - Integer: SHA-256

static const uint32_t sha_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

static inline uint32_t rotr32(uint32_t x, unsigned n) { return x >> n | x << (32 - n); }

static void sha256_block(uint32_t state[8], const uint8_t *p) {
    uint32_t w[64];
    for (int i = 0; i < 16; i++) {
        w[i] = (uint32_t)p[i * 4] << 24 | (uint32_t)p[i * 4 + 1] << 16 | (uint32_t)p[i * 4 + 2] << 8 | p[i * 4 + 3];
    }
    for (int i = 16; i < 64; i++) {
        uint32_t s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        uint32_t s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    uint32_t a = state[0], b = state[1], c = state[2], d = state[3];
    uint32_t e = state[4], f = state[5], g = state[6], h = state[7];
    for (int i = 0; i < 64; i++) {
        uint32_t s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        uint32_t t1 = h + s1 + ((e & f) ^ (~e & g)) + sha_k[i] + w[i];
        uint32_t s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        uint32_t t2 = s0 + ((a & b) ^ (a & c) ^ (b & c));
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

void cb_sha256(const uint8_t *data, size_t bytes, uint8_t digest[32]) {
    uint32_t state[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    };
    size_t offset = 0;
    for (; offset + 64 <= bytes; offset += 64) sha256_block(state, data + offset);

    uint8_t tail[128] = {0};
    size_t rest = bytes - offset;
    memcpy(tail, data + offset, rest);
    tail[rest] = 0x80;
    size_t padded = rest < 56 ? 64 : 128;
    uint64_t bits = (uint64_t)bytes * 8;
    for (int i = 0; i < 8; i++) tail[padded - 1 - i] = (uint8_t)(bits >> (8 * i));
    sha256_block(state, tail);
    if (padded == 128) sha256_block(state, tail + 64);

    for (int i = 0; i < 8; i++) {
        digest[i * 4] = (uint8_t)(state[i] >> 24);
        digest[i * 4 + 1] = (uint8_t)(state[i] >> 16);
        digest[i * 4 + 2] = (uint8_t)(state[i] >> 8);
        digest[i * 4 + 3] = (uint8_t)state[i];
    }
}

// MARK: - Branches: quicksort

static inline void swap32(uint32_t *a, uint32_t *b) {
    uint32_t t = *a;
    *a = *b;
    *b = t;
}

void cb_sort(uint32_t *v, size_t count) {
    while (count > 16) {
        // Ordering first, middle and last leaves the pivot off the last slot,
        // which is what keeps both sides of the partition non-empty.
        size_t mid = count / 2;
        if (v[mid] < v[0]) swap32(&v[mid], &v[0]);
        if (v[count - 1] < v[0]) swap32(&v[count - 1], &v[0]);
        if (v[count - 1] < v[mid]) swap32(&v[count - 1], &v[mid]);
        uint32_t pivot = v[mid];
        ptrdiff_t i = -1, j = (ptrdiff_t)count;
        for (;;) {
            do { i++; } while (v[i] < pivot);
            do { j--; } while (v[j] > pivot);
            if (i >= j) break;
            swap32(&v[i], &v[j]);
        }
        size_t left = (size_t)j + 1;
        // Recurse into the smaller side so the stack stays logarithmic.
        if (left < count - left) {
            cb_sort(v, left);
            v += left;
            count -= left;
        } else {
            cb_sort(v + left, count - left);
            count = left;
        }
    }
    for (size_t i = 1; i < count; i++) {
        uint32_t key = v[i];
        size_t j = i;
        while (j > 0 && v[j - 1] > key) {
            v[j] = v[j - 1];
            j--;
        }
        v[j] = key;
    }
}

// MARK: - Floating point: Mandelbrot

uint64_t cb_mandelbrot(double x0, double y0, double step, int32_t side, int32_t max_iterations) {
    uint64_t total = 0;
    for (int32_t py = 0; py < side; py++) {
        double ci = y0 + py * step;
        for (int32_t px = 0; px < side; px++) {
            double cr = x0 + px * step;
            double zr = 0, zi = 0;
            int32_t n = 0;
            while (n < max_iterations && zr * zr + zi * zi <= 4.0) {
                double next = zr * zr - zi * zi + cr;
                zi = 2 * zr * zi + ci;
                zr = next;
                n++;
            }
            total += (uint64_t)n;
        }
    }
    return total;
}

// MARK: - Vector: NEON matrix multiply

void cb_matmul(float *restrict c, const float *restrict a, const float *restrict b) {
    enum { N = CB_MATRIX_SIDE, LANES = N / 4 };
    for (int i = 0; i < N; i++) {
        // A whole output row stays in registers while it accumulates.
        float32x4_t row[LANES];
        for (int l = 0; l < LANES; l++) row[l] = vdupq_n_f32(0);
        for (int k = 0; k < N; k++) {
            float32x4_t scale = vdupq_n_f32(a[i * N + k]);
            const float *source = b + k * N;
            for (int l = 0; l < LANES; l++) row[l] = vfmaq_f32(row[l], scale, vld1q_f32(source + l * 4));
        }
        for (int l = 0; l < LANES; l++) vst1q_f32(c + i * N + l * 4, row[l]);
    }
}

// MARK: - Crypto: AES-128

/// SubBytes on one word. AESE also shifts rows, which changes nothing when all
/// four columns hold the same word.
static uint32_t aes_sub_word(uint32_t word) {
    uint8x16_t state = vaeseq_u8(vreinterpretq_u8_u32(vdupq_n_u32(word)), vdupq_n_u8(0));
    return vgetq_lane_u32(vreinterpretq_u32_u8(state), 0);
}

void cb_aes128_expand(const uint8_t key[16], uint8_t round_keys[176]) {
    static const uint8_t rcon[10] = {0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36};
    uint32_t w[44];
    memcpy(w, key, 16);
    for (int i = 4; i < 44; i++) {
        uint32_t t = w[i - 1];
        // Words are little-endian here, so RotWord is a right rotation.
        if (i % 4 == 0) t = aes_sub_word(rotr32(t, 8)) ^ rcon[i / 4 - 1];
        w[i] = w[i - 4] ^ t;
    }
    memcpy(round_keys, w, 176);
}

void cb_aes128_encrypt(const uint8_t round_keys[176], uint8_t *data, size_t bytes) {
    uint8x16_t k[11];
    for (int i = 0; i < 11; i++) k[i] = vld1q_u8(round_keys + i * 16);
    size_t offset = 0;
    for (; offset + 64 <= bytes; offset += 64) {
        uint8x16_t b0 = vld1q_u8(data + offset), b1 = vld1q_u8(data + offset + 16);
        uint8x16_t b2 = vld1q_u8(data + offset + 32), b3 = vld1q_u8(data + offset + 48);
        for (int r = 0; r < 9; r++) {
            b0 = vaesmcq_u8(vaeseq_u8(b0, k[r]));
            b1 = vaesmcq_u8(vaeseq_u8(b1, k[r]));
            b2 = vaesmcq_u8(vaeseq_u8(b2, k[r]));
            b3 = vaesmcq_u8(vaeseq_u8(b3, k[r]));
        }
        vst1q_u8(data + offset, veorq_u8(vaeseq_u8(b0, k[9]), k[10]));
        vst1q_u8(data + offset + 16, veorq_u8(vaeseq_u8(b1, k[9]), k[10]));
        vst1q_u8(data + offset + 32, veorq_u8(vaeseq_u8(b2, k[9]), k[10]));
        vst1q_u8(data + offset + 48, veorq_u8(vaeseq_u8(b3, k[9]), k[10]));
    }
    for (; offset + 16 <= bytes; offset += 16) {
        uint8x16_t block = vld1q_u8(data + offset);
        for (int r = 0; r < 9; r++) block = vaesmcq_u8(vaeseq_u8(block, k[r]));
        vst1q_u8(data + offset, veorq_u8(vaeseq_u8(block, k[9]), k[10]));
    }
}

// MARK: - Engine

typedef struct {
    _Alignas(CACHE_LINE) _Atomic uint64_t units;
} cb_counter;

typedef struct {
    cb_engine *engine;
    int32_t index;
    bool started;
    pthread_t thread;
    void *scratch;
} cb_worker;

struct cb_engine {
    cb_config config;
    cb_counter *counters;
    cb_worker *workers;
    _Atomic bool stop;
};

// Three matrices is the largest working set: 12 KiB.
#define SCRATCH_BYTES (16u * 1024u)

static uint64_t next_random(uint64_t *state) {
    uint64_t x = *state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    return *state = x;
}

static void *worker_main(void *argument) {
    cb_worker *worker = argument;
    cb_engine *e = worker->engine;
    _Atomic uint64_t *counter = &e->counters[worker->index].units;
    uint64_t state = 0x9E3779B97F4A7C15ull ^ ((uint64_t)(worker->index + 1) << 32);
    uint64_t total = 0;
    uint64_t round = 0;

    uint8_t *bytes = worker->scratch;
    uint32_t *keys = worker->scratch;
    float *a = worker->scratch, *b = a + MATRIX_CELLS, *c = b + MATRIX_CELLS;
    uint8_t round_keys[176];

    // Every test feeds its output back into its input or varies its input per
    // round, so no round can be computed ahead of time or dropped.
    switch (e->config.work) {
        case CB_WORK_INTEGER:
        case CB_WORK_CRYPTO: {
            for (uint32_t i = 0; i < SCRATCH_BYTES; i++) bytes[i] = (uint8_t)next_random(&state);
            uint8_t key[16];
            memcpy(key, bytes, 16);
            cb_aes128_expand(key, round_keys);
            break;
        }
        case CB_WORK_VECTOR:
            for (int i = 0; i < 2 * MATRIX_CELLS; i++) a[i] = (float)(next_random(&state) >> 40) * 0x1p-24f;
            break;
        default: break;
    }

    while (!atomic_load_explicit(&e->stop, memory_order_relaxed)) {
        switch (e->config.work) {
            case CB_WORK_INTEGER: {
                uint8_t digest[32];
                cb_sha256(bytes, HASH_BYTES, digest);
                memcpy(bytes, digest, sizeof(digest));
                total += HASH_BYTES;
                break;
            }
            case CB_WORK_BRANCH:
                for (uint32_t i = 0; i < SORT_KEYS; i++) keys[i] = (uint32_t)(next_random(&state) >> 32);
                cb_sort(keys, SORT_KEYS);
                state ^= keys[SORT_KEYS / 2];
                total += SORT_KEYS;
                break;
            case CB_WORK_FLOAT:
                total += cb_mandelbrot(-2.0 + (double)(round & 63) * 1e-4, -1.25, 2.5 / GRID_SIDE, GRID_SIDE, GRID_ITERATIONS);
                break;
            case CB_WORK_VECTOR:
                for (int i = 0; i < MATRIX_BATCH; i++) {
                    cb_matmul(c, a, b);
                    // Keeps values bounded while making each product depend on the last.
                    a[(round + (uint64_t)i) % MATRIX_CELLS] = c[i] * 0x1p-6f;
                }
                total += (uint64_t)CB_MATRIX_FLOPS * MATRIX_BATCH;
                break;
            case CB_WORK_CRYPTO:
                cb_aes128_encrypt(round_keys, bytes, CIPHER_BYTES);
                total += CIPHER_BYTES;
                break;
        }
        round++;
        atomic_store_explicit(counter, total, memory_order_relaxed);
    }
    return NULL;
}

cb_engine *cb_start(cb_config config) {
    if (config.threads < 1 || config.work < 0 || config.work >= CB_WORK_COUNT) return NULL;
    cb_engine *e = calloc(1, sizeof(cb_engine));
    if (!e) return NULL;
    e->config = config;
    atomic_init(&e->stop, false);
    e->workers = calloc((size_t)config.threads, sizeof(cb_worker));
    void *counters = NULL;
    if (!e->workers || posix_memalign(&counters, CACHE_LINE, sizeof(cb_counter) * (size_t)config.threads) != 0) {
        free(e->workers);
        free(e);
        return NULL;
    }
    memset(counters, 0, sizeof(cb_counter) * (size_t)config.threads);
    e->counters = counters;

    // macOS has no core pinning. QoS is the supported way to steer work: user
    // interactive prefers P-cores, background is confined to E-cores.
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    qos_class_t qos = config.cores == CB_CORES_EFFICIENCY ? QOS_CLASS_BACKGROUND : QOS_CLASS_USER_INTERACTIVE;
    pthread_attr_set_qos_class_np(&attributes, qos, 0);

    bool failed = false;
    for (int32_t i = 0; i < config.threads && !failed; i++) {
        cb_worker *worker = &e->workers[i];
        worker->engine = e;
        worker->index = i;
        if (posix_memalign(&worker->scratch, CACHE_LINE, SCRATCH_BYTES) != 0) {
            worker->scratch = NULL;
            failed = true;
        } else if (pthread_create(&worker->thread, &attributes, worker_main, worker) != 0) {
            failed = true;
        } else {
            worker->started = true;
        }
    }
    pthread_attr_destroy(&attributes);
    if (failed) {
        cb_stop(e);
        return NULL;
    }
    return e;
}

uint64_t cb_snapshot(const cb_engine *e, uint64_t *per_thread, int32_t capacity) {
    uint64_t total = 0;
    for (int32_t i = 0; i < e->config.threads; i++) {
        uint64_t value = atomic_load_explicit(&e->counters[i].units, memory_order_relaxed);
        if (per_thread && i < capacity) per_thread[i] = value;
        total += value;
    }
    return total;
}

void cb_stop(cb_engine *e) {
    if (!e) return;
    atomic_store(&e->stop, true);
    for (int32_t i = 0; i < e->config.threads; i++) {
        cb_worker *worker = &e->workers[i];
        if (worker->started) pthread_join(worker->thread, NULL);
        free(worker->scratch);
    }
    free(e->workers);
    free(e->counters);
    free(e);
}
