#include "powerprobes.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <libproc.h>
#include <mach/mach.h>
#include <pthread.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>

// MARK: - SMC

// Layout of the AppleSMC struct method's input and output.
typedef struct {
    uint32_t key;
    struct { uint8_t major, minor, build, reserved; uint16_t release; } version;
    struct { uint16_t version, length; uint32_t cpu, gpu, mem; } limits;
    struct { uint32_t size, type; uint8_t attributes; } info;
    uint8_t result, status, command;
    uint32_t data32;
    uint8_t bytes[32];
} smc_param;

enum { SMC_METHOD = 2, SMC_READ_BYTES = 5, SMC_READ_INFO = 9 };
static const uint32_t SMC_TYPE_FLOAT = 0x666c7420; // "flt "

static io_connect_t smc_connection = 0;

bool pp_smc_open(void) {
    if (smc_connection) return true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return false;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &smc_connection);
    IOObjectRelease(service);
    return result == KERN_SUCCESS;
}

static bool smc_call(smc_param *input, smc_param *output) {
    size_t size = sizeof(smc_param);
    memset(output, 0, sizeof(smc_param));
    return IOConnectCallStructMethod(smc_connection, SMC_METHOD, input, sizeof(smc_param), output, &size) == KERN_SUCCESS
        && output->result == 0;
}

bool pp_smc_read_float(const char *key, float *out) {
    if (!smc_connection || strlen(key) != 4) return false;
    smc_param input, info, data;
    memset(&input, 0, sizeof(input));
    input.key = (uint32_t)(uint8_t)key[0] << 24 | (uint32_t)(uint8_t)key[1] << 16
              | (uint32_t)(uint8_t)key[2] << 8 | (uint32_t)(uint8_t)key[3];
    input.command = SMC_READ_INFO;
    if (!smc_call(&input, &info)) return false;
    if (info.info.type != SMC_TYPE_FLOAT || info.info.size != sizeof(float)) return false;
    input.info.size = info.info.size;
    input.command = SMC_READ_BYTES;
    if (!smc_call(&input, &data)) return false;
    memcpy(out, data.bytes, sizeof(float));
    return true;
}

// MARK: - IOReport

typedef void *ior_subscription;
typedef CFDictionaryRef (*ior_copy_group_fn)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef ior_subscription (*ior_subscribe_fn)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*ior_sample_fn)(ior_subscription, CFMutableDictionaryRef, CFTypeRef);
typedef CFStringRef (*ior_name_fn)(CFDictionaryRef);
typedef int64_t (*ior_value_fn)(CFDictionaryRef, int32_t);

static ior_subscription ior_subscription_ref = NULL;
static CFMutableDictionaryRef ior_channels = NULL;
static ior_sample_fn ior_sample = NULL;
static ior_name_fn ior_channel_name = NULL;
static ior_value_fn ior_integer_value = NULL;

typedef CFStringRef (*ior_state_name_fn)(CFDictionaryRef, int32_t);
typedef int32_t (*ior_state_count_fn)(CFDictionaryRef);

static ior_copy_group_fn ior_copy_group = NULL;
static ior_subscribe_fn ior_subscribe = NULL;
static ior_state_count_fn ior_state_count = NULL;
static ior_state_name_fn ior_state_name = NULL;
static ior_value_fn ior_state_residency = NULL;
static pthread_once_t ior_once = PTHREAD_ONCE_INIT;
static bool ior_loaded = false;

static void ior_load(void) {
    void *library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW);
    if (!library) return;
    ior_copy_group = (ior_copy_group_fn)dlsym(library, "IOReportCopyChannelsInGroup");
    ior_subscribe = (ior_subscribe_fn)dlsym(library, "IOReportCreateSubscription");
    ior_sample = (ior_sample_fn)dlsym(library, "IOReportCreateSamples");
    ior_channel_name = (ior_name_fn)dlsym(library, "IOReportChannelGetChannelName");
    ior_integer_value = (ior_value_fn)dlsym(library, "IOReportSimpleGetIntegerValue");
    ior_state_count = (ior_state_count_fn)dlsym(library, "IOReportStateGetCount");
    ior_state_name = (ior_state_name_fn)dlsym(library, "IOReportStateGetNameForIndex");
    ior_state_residency = (ior_value_fn)dlsym(library, "IOReportStateGetResidency");
    ior_loaded = ior_copy_group && ior_subscribe && ior_sample && ior_channel_name && ior_integer_value
        && ior_state_count && ior_state_name && ior_state_residency;
}

bool pp_gpu_energy_open(void) {
    if (ior_subscription_ref) return true;
    pthread_once(&ior_once, ior_load);
    if (!ior_loaded) return false;
    ior_copy_group_fn copy_group = ior_copy_group;
    ior_subscribe_fn subscribe = ior_subscribe;

    CFDictionaryRef channels = copy_group(CFSTR("Energy Model"), NULL, 0, 0, 0);
    if (!channels) return false;
    CFMutableDictionaryRef mutable_channels = CFDictionaryCreateMutableCopy(NULL, 0, channels);
    CFRelease(channels);
    ior_subscription_ref = subscribe(NULL, mutable_channels, &ior_channels, 0, NULL);
    CFRelease(mutable_channels);
    return ior_subscription_ref != NULL;
}

bool pp_gpu_energy_read(int64_t *nanojoules) {
    if (!ior_subscription_ref) return false;
    CFDictionaryRef sample = ior_sample(ior_subscription_ref, ior_channels, NULL);
    if (!sample) return false;
    bool found = false;
    CFArrayRef items = CFDictionaryGetValue(sample, CFSTR("IOReportChannels"));
    if (items) {
        CFIndex count = CFArrayGetCount(items);
        // "GPU Energy" is the only live channel here, and is reported in nJ. The
        // mJ channels (CPU Energy, DRAM, ...) were observed frozen on macOS 27.
        for (CFIndex i = count - 1; i >= 0 && !found; i--) {
            CFDictionaryRef item = CFArrayGetValueAtIndex(items, i);
            CFStringRef name = ior_channel_name(item);
            if (name && CFStringCompare(name, CFSTR("GPU Energy"), 0) == kCFCompareEqualTo) {
                *nanojoules = ior_integer_value(item, 0);
                found = true;
            }
        }
    }
    CFRelease(sample);
    return found;
}

// MARK: - Per-core performance states

static ior_subscription cpu_subscription = NULL;
static CFMutableDictionaryRef cpu_channels = NULL;

bool pp_cpu_states_open(void) {
    if (cpu_subscription) return true;
    pthread_once(&ior_once, ior_load);
    if (!ior_loaded) return false;
    CFDictionaryRef channels = ior_copy_group(CFSTR("CPU Stats"), CFSTR("CPU Core Performance States"), 0, 0, 0);
    if (!channels) return false;
    CFMutableDictionaryRef mutable_channels = CFDictionaryCreateMutableCopy(NULL, 0, channels);
    CFRelease(channels);
    cpu_subscription = ior_subscribe(NULL, mutable_channels, &cpu_channels, 0, NULL);
    CFRelease(mutable_channels);
    return cpu_subscription != NULL;
}

int32_t pp_cpu_states_read(char *names, int32_t *state_counts, uint64_t *idle, uint64_t *residency, int32_t capacity) {
    if (!cpu_subscription) return 0;
    CFDictionaryRef sample = ior_sample(cpu_subscription, cpu_channels, NULL);
    if (!sample) return 0;
    int32_t cores = 0;
    CFArrayRef items = CFDictionaryGetValue(sample, CFSTR("IOReportChannels"));
    CFIndex count = items ? CFArrayGetCount(items) : 0;
    for (CFIndex i = 0; i < count && cores < capacity; i++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(items, i);
        CFStringRef name = ior_channel_name(item);
        char *name_out = names + cores * PP_CORE_NAME_BYTES;
        if (!name || !CFStringGetCString(name, name_out, PP_CORE_NAME_BYTES, kCFStringEncodingUTF8)) continue;
        uint64_t *states_out = residency + cores * PP_MAX_CORE_STATES;
        int32_t states = 0;
        idle[cores] = 0;
        int32_t total = ior_state_count(item);
        for (int32_t state = 0; state < total; state++) {
            int64_t value = ior_state_residency(item, state);
            if (value < 0) value = 0;
            // Running states are named for their voltage and performance index,
            // V0P6 being the slowest. Everything else (IDLE, DOWN, OFF) is not running.
            char label[16] = "";
            CFStringRef state_label = ior_state_name(item, state);
            if (state_label) CFStringGetCString(state_label, label, sizeof(label), kCFStringEncodingUTF8);
            if (label[0] == 'V' && label[1] >= '0' && label[1] <= '9') {
                if (states < PP_MAX_CORE_STATES) states_out[states++] = (uint64_t)value;
            } else {
                idle[cores] += (uint64_t)value;
            }
        }
        state_counts[cores] = states;
        cores++;
    }
    CFRelease(sample);
    return cores;
}

// MARK: - Process energy

bool pp_self_cpu_energy(uint64_t *nanojoules) {
    struct rusage_info_v6 usage;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&usage) != 0) return false;
    *nanojoules = usage.ri_energy_nj;
    return true;
}
