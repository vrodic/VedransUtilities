#include "storageprobes.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <string.h>

/// Copies a space-padded identify field into a trimmed C string.
static void copy_trimmed(char *destination, size_t size, const uint8_t *source, size_t length) {
    size_t end = length < size - 1 ? length : size - 1;
    while (end > 0 && (source[end - 1] == ' ' || source[end - 1] == 0)) end--;
    size_t start = 0;
    while (start < end && source[start] == ' ') start++;
    memcpy(destination, source + start, end - start);
    destination[end - start] = 0;
}

static CFTypeRef search_property(io_service_t service, CFStringRef key) {
    return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key, kCFAllocatorDefault, kIORegistryIterateRecursively);
}

static void read_registry_details(io_service_t service, sp_drive *drive) {
    CFTypeRef bsd = search_property(service, CFSTR("BSD Name"));
    if (bsd && CFGetTypeID(bsd) == CFStringGetTypeID()) {
        CFStringGetCString(bsd, drive->bsd_name, sizeof(drive->bsd_name), kCFStringEncodingUTF8);
    }
    if (bsd) CFRelease(bsd);

    CFTypeRef size = search_property(service, CFSTR("Size"));
    if (size && CFGetTypeID(size) == CFNumberGetTypeID()) {
        long long bytes = 0;
        CFNumberGetValue(size, kCFNumberLongLongType, &bytes);
        drive->capacity_bytes = (uint64_t)bytes;
    }
    if (size) CFRelease(size);

    CFTypeRef protocol = IORegistryEntryCreateCFProperty(service, CFSTR("Protocol Characteristics"), kCFAllocatorDefault, 0);
    if (protocol && CFGetTypeID(protocol) == CFDictionaryGetTypeID()) {
        CFStringRef location = CFDictionaryGetValue(protocol, CFSTR("Physical Interconnect Location"));
        drive->is_internal = location && CFStringCompare(location, CFSTR("Internal"), 0) == kCFCompareEqualTo;
    }
    if (protocol) CFRelease(protocol);

    // A fallback name for drives whose identify data can't be read.
    CFTypeRef device = IORegistryEntryCreateCFProperty(service, CFSTR("Device Characteristics"), kCFAllocatorDefault, 0);
    if (device && CFGetTypeID(device) == CFDictionaryGetTypeID()) {
        CFStringRef product = CFDictionaryGetValue(device, CFSTR("Product Name"));
        if (product) CFStringGetCString(product, drive->model, sizeof(drive->model), kCFStringEncodingUTF8);
    }
    if (device) CFRelease(device);
}

static bool read_smart(io_service_t service, sp_drive *drive) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    if (IOCreatePlugInInterfaceForService(service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score) != kIOReturnSuccess || !plugin) {
        return false;
    }
    IONVMeSMARTInterface **smart = NULL;
    HRESULT result = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    if (result != S_OK || !smart) {
        IODestroyPlugInInterface(plugin);
        return false;
    }

    bool ok = false;
    NVMeSMARTData data;
    memset(&data, 0, sizeof(data));
    if ((*smart)->SMARTReadData(smart, &data) == kIOReturnSuccess) {
        drive->critical_warning = data.CRITICAL_WARNING;
        drive->temperature_kelvin = data.TEMPERATURE;
        drive->available_spare = data.AVAILABLE_SPARE;
        drive->available_spare_threshold = data.AVAILABLE_SPARE_THRESHOLD;
        drive->percentage_used = data.PERCENTAGE_USED;
        drive->data_units_read = data.DATA_UNITS_READ[0];
        drive->data_units_written = data.DATA_UNITS_WRITTEN[0];
        drive->host_read_commands = data.HOST_READ_COMMANDS[0];
        drive->host_write_commands = data.HOST_WRITE_COMMANDS[0];
        drive->controller_busy_minutes = data.CONTROLLER_BUSY_TIME[0];
        drive->power_cycles = data.POWER_CYCLES[0];
        drive->power_on_hours = data.POWER_ON_HOURS[0];
        drive->unsafe_shutdowns = data.UNSAFE_SHUTDOWNS[0];
        drive->media_errors = data.MEDIA_ERRORS[0];
        drive->error_log_entries = data.NUM_ERROR_INFO_LOG_ENTRIES[0];
        ok = true;
    }

    // Identify data is 4 KiB, too big for the stack of a background thread's taste.
    static NVMeIdentifyControllerStruct identify;
    memset(&identify, 0, sizeof(identify));
    if ((*smart)->GetIdentifyData(smart, &identify, 0) == kIOReturnSuccess) {
        copy_trimmed(drive->model, sizeof(drive->model), identify.MODEL_NUMBER, sizeof(identify.MODEL_NUMBER));
        copy_trimmed(drive->firmware, sizeof(drive->firmware), identify.FW_REVISION, sizeof(identify.FW_REVISION));
    }
    // The plugin owns the connection to the drive, so it must outlive every call.
    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    return ok;
}

int32_t sp_read_drives(sp_drive *drives, int32_t capacity) {
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONVMeBlockStorageDevice"), &iterator) != kIOReturnSuccess) {
        return 0;
    }
    int32_t count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) && count < capacity) {
        sp_drive *drive = &drives[count];
        memset(drive, 0, sizeof(sp_drive));
        read_registry_details(service, drive);
        CFTypeRef capable = IORegistryEntryCreateCFProperty(service, CFSTR("NVMe SMART Capable"), kCFAllocatorDefault, 0);
        if (capable == kCFBooleanTrue) drive->has_smart = read_smart(service, drive);
        if (capable) CFRelease(capable);
        IOObjectRelease(service);
        count++;
    }
    if (service) IOObjectRelease(service);
    IOObjectRelease(iterator);
    return count;
}
