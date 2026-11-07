#include "membench.h"

#include <arm_neon.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#if !defined(__aarch64__)
#error "VedransUtilities targets Apple Silicon."
#endif

// Work between counter updates and stop checks. Small enough that sampling at
// 20 Hz stays smooth even for slow operations, large enough to cost nothing.
#define CHUNK_BYTES (256u * 1024u)
#define FILL_CHUNK_BYTES (4u * 1024u * 1024u)
#define CACHE_LINE 128

// MARK: - Kernels

void mb_kernel_read(const void *src, size_t bytes) {
    const char *p = src;
    const char *end = p + (bytes & ~(size_t)255);
    if (p == end) return;
    __asm__ volatile(
        "1:\n"
        "ldp q16, q17, [%[p], #0]\n"
        "ldp q18, q19, [%[p], #32]\n"
        "ldp q20, q21, [%[p], #64]\n"
        "ldp q22, q23, [%[p], #96]\n"
        "ldp q16, q17, [%[p], #128]\n"
        "ldp q18, q19, [%[p], #160]\n"
        "ldp q20, q21, [%[p], #192]\n"
        "ldp q22, q23, [%[p], #224]\n"
        "add %[p], %[p], #256\n"
        "cmp %[p], %[e]\n"
        "b.lo 1b\n"
        : [p] "+r"(p)
        : [e] "r"(end)
        : "cc", "memory", "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23");
}

void mb_kernel_write(void *dst, size_t bytes, uint8_t value) {
    char *p = dst;
    char *end = p + (bytes & ~(size_t)255);
    if (p == end) return;
    uint8x16_t v = vdupq_n_u8(value);
    __asm__ volatile(
        "1:\n"
        "stp %q[v], %q[v], [%[p], #0]\n"
        "stp %q[v], %q[v], [%[p], #32]\n"
        "stp %q[v], %q[v], [%[p], #64]\n"
        "stp %q[v], %q[v], [%[p], #96]\n"
        "stp %q[v], %q[v], [%[p], #128]\n"
        "stp %q[v], %q[v], [%[p], #160]\n"
        "stp %q[v], %q[v], [%[p], #192]\n"
        "stp %q[v], %q[v], [%[p], #224]\n"
        "add %[p], %[p], #256\n"
        "cmp %[p], %[e]\n"
        "b.lo 1b\n"
        : [p] "+r"(p)
        : [e] "r"(end), [v] "w"(v)
        : "cc", "memory");
}

void mb_kernel_copy(void *dst, const void *src, size_t bytes) {
    const char *s = src;
    char *d = dst;
    const char *end = s + (bytes & ~(size_t)127);
    if (s == end) return;
    __asm__ volatile(
        "1:\n"
        "ldp q16, q17, [%[s], #0]\n"
        "ldp q18, q19, [%[s], #32]\n"
        "ldp q20, q21, [%[s], #64]\n"
        "ldp q22, q23, [%[s], #96]\n"
        "stp q16, q17, [%[d], #0]\n"
        "stp q18, q19, [%[d], #32]\n"
        "stp q20, q21, [%[d], #64]\n"
        "stp q22, q23, [%[d], #96]\n"
        "add %[s], %[s], #128\n"
        "add %[d], %[d], #128\n"
        "cmp %[s], %[e]\n"
        "b.lo 1b\n"
        : [s] "+r"(s), [d] "+r"(d)
        : [e] "r"(end)
        : "cc", "memory", "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23");
}

void mb_kernel_triad(double *a, const double *b, const double *c, size_t bytes, double scalar) {
    const char *pb = (const char *)b;
    const char *pc = (const char *)c;
    char *pa = (char *)a;
    const char *end = pb + (bytes & ~(size_t)63);
    if (pb == end) return;
    float64x2_t s = vdupq_n_f64(scalar);
    __asm__ volatile(
        "1:\n"
        "ldp q16, q17, [%[b], #0]\n"
        "ldp q18, q19, [%[b], #32]\n"
        "ldp q20, q21, [%[c], #0]\n"
        "ldp q22, q23, [%[c], #32]\n"
        "fmla v16.2d, v20.2d, %[s].2d\n"
        "fmla v17.2d, v21.2d, %[s].2d\n"
        "fmla v18.2d, v22.2d, %[s].2d\n"
        "fmla v19.2d, v23.2d, %[s].2d\n"
        "stp q16, q17, [%[a], #0]\n"
        "stp q18, q19, [%[a], #32]\n"
        "add %[a], %[a], #64\n"
        "add %[b], %[b], #64\n"
        "add %[c], %[c], #64\n"
        "cmp %[b], %[e]\n"
        "b.lo 1b\n"
        : [a] "+r"(pa), [b] "+r"(pb), [c] "+r"(pc)
        : [e] "r"(end), [s] "w"(s)
        : "cc", "memory", "v16", "v17", "v18", "v19", "v20", "v21", "v22", "v23");
}

uint64_t mb_kernel_random(const void *base, uint64_t block, size_t accesses, uint64_t state) {
    if (accesses == 0) return state;
    uint64_t mask = (block - 1) & ~(uint64_t)(CACHE_LINE - 1);
    uint64_t index, loaded;
    size_t remaining = accesses;
    // xorshift64: cheap enough not to dominate the measurement, and the loads
    // don't depend on each other, so this measures random throughput (not latency).
    __asm__ volatile(
        "1:\n"
        "eor %[x], %[x], %[x], lsl #13\n"
        "eor %[x], %[x], %[x], lsr #7\n"
        "eor %[x], %[x], %[x], lsl #17\n"
        "and %[i], %[x], %[m]\n"
        "ldr %[t], [%[b], %[i]]\n"
        "subs %[n], %[n], #1\n"
        "b.ne 1b\n"
        : [x] "+r"(state), [n] "+r"(remaining), [i] "=&r"(index), [t] "=&r"(loaded)
        : [b] "r"(base), [m] "r"(mask)
        : "cc", "memory");
    return state;
}

// MARK: - Engine

typedef struct {
    _Alignas(CACHE_LINE) _Atomic uint64_t bytes;
    char padding[CACHE_LINE - sizeof(_Atomic uint64_t)];
} mb_counter;

typedef struct {
    mb_engine *engine;
    int32_t index;
    bool started;
    pthread_t thread;
    void *buffers[3];
} mb_worker;

struct mb_engine {
    mb_config config;
    mb_counter *counters;
    mb_worker *workers;
    int32_t started_threads;

    pthread_mutex_t lock;
    pthread_cond_t changed;
    int32_t ready;
    bool failed;
    bool stop_requested;

    _Atomic bool stop;
};

int32_t mb_buffers_for_op(int32_t op) {
    switch (op) {
        case MB_OP_COPY: return 2;
        case MB_OP_TRIAD: return 3;
        default: return 1;
    }
}

static uint64_t op_byte_multiplier(int32_t op) {
    // STREAM convention: count every byte that crosses the memory interface,
    // so a copy moves 2x its length and a triad 3x.
    switch (op) {
        case MB_OP_COPY: return 2;
        case MB_OP_TRIAD: return 3;
        default: return 1;
    }
}

static void fill_doubles(double *buffer, uint64_t block, double value) {
    uint64_t count = block / sizeof(double);
    for (uint64_t i = 0; i < count; i++) buffer[i] = value;
}

/// Allocates and faults in buffers with non-zero data, so reads hit real pages
/// rather than the shared zero page. Stops early if asked to.
static bool prepare_buffers(mb_worker *worker) {
    mb_engine *e = worker->engine;
    uint64_t block = e->config.block_bytes;
    int32_t count = mb_buffers_for_op(e->config.op);
    for (int32_t i = 0; i < count; i++) {
        void *m = mmap(NULL, block, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (m == MAP_FAILED) return false;
        worker->buffers[i] = m;
        if (e->config.op == MB_OP_TRIAD) {
            // Fixed inputs keep the output stable and clear of denormals.
            fill_doubles(m, block, i == 2 ? 2.0 : 1.0);
        } else {
            for (uint64_t off = 0; off < block; off += FILL_CHUNK_BYTES) {
                if (atomic_load_explicit(&e->stop, memory_order_relaxed)) return true;
                uint64_t n = block - off < FILL_CHUNK_BYTES ? block - off : FILL_CHUNK_BYTES;
                memset((char *)m + off, 0x5A, n);
            }
        }
    }
    return true;
}

static void *worker_main(void *argument) {
    mb_worker *worker = argument;
    mb_engine *e = worker->engine;
    bool prepared = prepare_buffers(worker);

    pthread_mutex_lock(&e->lock);
    if (!prepared) e->failed = true;
    e->ready++;
    pthread_cond_broadcast(&e->changed);
    while (e->ready < e->started_threads && !e->stop_requested) {
        pthread_cond_wait(&e->changed, &e->lock);
    }
    bool run = !e->failed && !e->stop_requested;
    pthread_mutex_unlock(&e->lock);
    if (!run) return NULL;

    const int32_t op = e->config.op;
    const uint64_t block = e->config.block_bytes;
    const uint64_t multiplier = op_byte_multiplier(op);
    _Atomic uint64_t *counter = &e->counters[worker->index].bytes;
    char *a = worker->buffers[0];
    char *b = worker->buffers[1];
    char *c = worker->buffers[2];
    uint64_t position = 0;
    uint64_t total = 0;
    uint64_t random_state = 0x9E3779B97F4A7C15ull ^ ((uint64_t)(worker->index + 1) << 32);

    while (!atomic_load_explicit(&e->stop, memory_order_relaxed)) {
        uint64_t done = 0;
        if (op == MB_OP_RANDOM) {
            random_state = mb_kernel_random(a, block, CHUNK_BYTES / MB_RANDOM_LINE_BYTES, random_state);
            done = CHUNK_BYTES;
        } else {
            while (done < CHUNK_BYTES) {
                uint64_t n = block - position;
                if (n > CHUNK_BYTES - done) n = CHUNK_BYTES - done;
                switch (op) {
                    case MB_OP_READ: mb_kernel_read(a + position, n); break;
                    case MB_OP_WRITE: mb_kernel_write(a + position, n, 0xA5); break;
                    case MB_OP_COPY: mb_kernel_copy(b + position, a + position, n); break;
                    case MB_OP_TRIAD:
                        mb_kernel_triad((double *)(a + position), (const double *)(b + position),
                                        (const double *)(c + position), n, 3.0);
                        break;
                }
                position += n;
                if (position >= block) position = 0;
                done += n;
            }
        }
        total += done * multiplier;
        atomic_store_explicit(counter, total, memory_order_relaxed);
    }
    return NULL;
}

mb_engine *mb_start(mb_config config) {
    if (config.threads < 1 || config.block_bytes < 4096) return NULL;
    // Power-of-two blocks keep kernels' rounding and the random mask exact.
    uint64_t block = 4096;
    while (block * 2 <= config.block_bytes) block *= 2;
    config.block_bytes = block;

    mb_engine *e = calloc(1, sizeof(mb_engine));
    if (!e) return NULL;
    e->config = config;
    void *counters = NULL;
    if (posix_memalign(&counters, CACHE_LINE, sizeof(mb_counter) * (size_t)config.threads) != 0) {
        free(e);
        return NULL;
    }
    memset(counters, 0, sizeof(mb_counter) * (size_t)config.threads);
    e->counters = counters;
    e->workers = calloc((size_t)config.threads, sizeof(mb_worker));
    pthread_mutex_init(&e->lock, NULL);
    pthread_cond_init(&e->changed, NULL);
    atomic_init(&e->stop, false);

    // macOS has no core pinning. QoS is the supported way to steer work: user
    // interactive prefers P-cores, background is confined to E-cores.
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    qos_class_t qos = config.cores == MB_CORES_EFFICIENCY ? QOS_CLASS_BACKGROUND : QOS_CLASS_USER_INTERACTIVE;
    pthread_attr_set_qos_class_np(&attributes, qos, 0);

    // Hold the lock so workers can't see a partial started_threads count.
    pthread_mutex_lock(&e->lock);
    for (int32_t i = 0; i < config.threads; i++) {
        mb_worker *worker = &e->workers[i];
        worker->engine = e;
        worker->index = i;
        if (pthread_create(&worker->thread, &attributes, worker_main, worker) != 0) {
            e->failed = true;
            break;
        }
        worker->started = true;
        e->started_threads++;
    }
    pthread_cond_broadcast(&e->changed);
    pthread_mutex_unlock(&e->lock);
    pthread_attr_destroy(&attributes);
    return e;
}

bool mb_wait_ready(mb_engine *e) {
    pthread_mutex_lock(&e->lock);
    while (e->ready < e->started_threads && !e->stop_requested) {
        pthread_cond_wait(&e->changed, &e->lock);
    }
    bool ok = !e->failed;
    pthread_mutex_unlock(&e->lock);
    return ok;
}

uint64_t mb_snapshot(const mb_engine *e, uint64_t *per_thread, int32_t capacity) {
    uint64_t total = 0;
    for (int32_t i = 0; i < e->config.threads; i++) {
        uint64_t value = atomic_load_explicit(&e->counters[i].bytes, memory_order_relaxed);
        if (per_thread && i < capacity) per_thread[i] = value;
        total += value;
    }
    return total;
}

void mb_stop(mb_engine *e) {
    if (!e) return;
    atomic_store(&e->stop, true);
    pthread_mutex_lock(&e->lock);
    e->stop_requested = true;
    pthread_cond_broadcast(&e->changed);
    pthread_mutex_unlock(&e->lock);

    int32_t buffers = mb_buffers_for_op(e->config.op);
    for (int32_t i = 0; i < e->config.threads; i++) {
        mb_worker *worker = &e->workers[i];
        if (worker->started) pthread_join(worker->thread, NULL);
        for (int32_t b = 0; b < buffers; b++) {
            if (worker->buffers[b]) munmap(worker->buffers[b], e->config.block_bytes);
        }
    }
    pthread_mutex_destroy(&e->lock);
    pthread_cond_destroy(&e->changed);
    free(e->workers);
    free(e->counters);
    free(e);
}
