// HID temperature sensors (private IOKit API, stable since macOS 11 but undocumented).
// Apple silicon exposes its PMU die sensors, NAND and battery gauge temperatures here.
#include "CSystem.h"
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15
#define kVendorPage 0xff00
#define kTemperatureUsage 5

int heron_hid_temperatures(heron_hid_temp *out, int max) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return 0;

    int page = kVendorPage, usage = kTemperatureUsage;
    CFNumberRef pageNum = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef usageNum = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[] = { pageNum, usageNum };
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);

    int count = 0;
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (services) {
        CFIndex n = CFArrayGetCount(services);
        for (CFIndex i = 0; i < n && count < max; i++) {
            IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            CFStringRef name = (CFStringRef)IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
            IOHIDEventRef ev = IOHIDServiceClientCopyEvent(svc, kIOHIDEventTypeTemperature, 0, 0);
            // "Product" is a string on every Mac seen; anything else would crash CFStringGetCString.
            if (name && ev && CFGetTypeID(name) == CFStringGetTypeID()) {
                double c = IOHIDEventGetFloatValue(ev, kIOHIDEventTypeTemperature << 16);
                if (c > -50 && c < 150) {   // drop obviously broken readings
                    CFStringGetCString(name, out[count].name, sizeof(out[count].name), kCFStringEncodingUTF8);
                    out[count].celsius = c;
                    count++;
                }
            }
            if (ev) CFRelease(ev);
            if (name) CFRelease(name);
        }
        CFRelease(services);
    }
    CFRelease(match);
    CFRelease(pageNum);
    CFRelease(usageNum);
    CFRelease(client);
    return count;
}
