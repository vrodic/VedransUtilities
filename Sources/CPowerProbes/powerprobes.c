#include "powerprobes.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <libproc.h>
#include <mach/mach.h>
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

bool pp_gpu_energy_open(void) {
    if (ior_subscription_ref) return true;
    void *library = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW);
    if (!library) return false;
    ior_copy_group_fn copy_group = (ior_copy_group_fn)dlsym(library, "IOReportCopyChannelsInGroup");
    ior_subscribe_fn subscribe = (ior_subscribe_fn)dlsym(library, "IOReportCreateSubscription");
    ior_sample = (ior_sample_fn)dlsym(library, "IOReportCreateSamples");
    ior_channel_name = (ior_name_fn)dlsym(library, "IOReportChannelGetChannelName");
    ior_integer_value = (ior_value_fn)dlsym(library, "IOReportSimpleGetIntegerValue");
    if (!copy_group || !subscribe || !ior_sample || !ior_channel_name || !ior_integer_value) return false;

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

// MARK: - Process energy

bool pp_self_cpu_energy(uint64_t *nanojoules) {
    struct rusage_info_v6 usage;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&usage) != 0) return false;
    *nanojoules = usage.ri_energy_nj;
    return true;
}
