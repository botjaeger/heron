// IOReport energy counters (private libIOReport, loaded at run time with dlopen because
// the SDK ships no headers or link stub for it). This is the data `powermetrics` shows,
// readable without root. Also the CPU clusters' performance-state residencies (clock speed).
#include "CSystem.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

typedef struct __IOReportSubscriptionCF *IOReportSubscriptionRef;

typedef CFMutableDictionaryRef (*CopyChannelsInGroup_t)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
typedef IOReportSubscriptionRef (*CreateSubscription_t)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
typedef CFDictionaryRef (*CreateSamples_t)(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
typedef CFDictionaryRef (*CreateSamplesDelta_t)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
typedef CFStringRef (*ChannelGetString_t)(CFDictionaryRef);
typedef int64_t (*SimpleGetIntegerValue_t)(CFDictionaryRef, int32_t);
typedef int32_t (*StateGetCount_t)(CFDictionaryRef);
typedef CFStringRef (*StateGetName_t)(CFDictionaryRef, int32_t);
typedef int64_t (*StateGetResidency_t)(CFDictionaryRef, int32_t);

struct heron_ioreport {
    void *lib;
    CreateSamples_t createSamples;
    CreateSamplesDelta_t createDelta;
    ChannelGetString_t getGroup, getName, getUnit;
    SimpleGetIntegerValue_t getInt;
    StateGetCount_t stateCount;         // NULL when this libIOReport lacks the state API
    StateGetName_t stateName;
    StateGetResidency_t stateResidency;
    IOReportSubscriptionRef sub;
    CFMutableDictionaryRef subbed;
    CFDictionaryRef last;
};

static heron_ioreport *create(CFStringRef group, CFStringRef subgroup) {
    void *lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY);
    if (!lib) return NULL;
    CopyChannelsInGroup_t copyChannels = (CopyChannelsInGroup_t)dlsym(lib, "IOReportCopyChannelsInGroup");
    CreateSubscription_t createSub = (CreateSubscription_t)dlsym(lib, "IOReportCreateSubscription");
    heron_ioreport *r = calloc(1, sizeof(heron_ioreport));
    if (!r) { dlclose(lib); return NULL; }
    r->lib = lib;
    r->createSamples = (CreateSamples_t)dlsym(lib, "IOReportCreateSamples");
    r->createDelta = (CreateSamplesDelta_t)dlsym(lib, "IOReportCreateSamplesDelta");
    r->getGroup = (ChannelGetString_t)dlsym(lib, "IOReportChannelGetGroup");
    r->getName = (ChannelGetString_t)dlsym(lib, "IOReportChannelGetChannelName");
    r->getUnit = (ChannelGetString_t)dlsym(lib, "IOReportChannelGetUnitLabel");
    r->getInt = (SimpleGetIntegerValue_t)dlsym(lib, "IOReportSimpleGetIntegerValue");
    r->stateCount = (StateGetCount_t)dlsym(lib, "IOReportStateGetCount");
    r->stateName = (StateGetName_t)dlsym(lib, "IOReportStateGetNameForIndex");
    r->stateResidency = (StateGetResidency_t)dlsym(lib, "IOReportStateGetResidency");
    if (!copyChannels || !createSub || !r->createSamples || !r->createDelta || !r->getGroup || !r->getName || !r->getUnit || !r->getInt) {
        heron_ioreport_destroy(r);
        return NULL;
    }
    CFMutableDictionaryRef channels = copyChannels(group, subgroup, 0, 0, 0);
    if (!channels) { heron_ioreport_destroy(r); return NULL; }
    CFMutableDictionaryRef subbed = NULL;
    r->sub = createSub(NULL, channels, &subbed, 0, NULL);
    r->subbed = subbed;
    CFRelease(channels);
    if (!r->sub || !r->subbed) { heron_ioreport_destroy(r); return NULL; }
    return r;
}

heron_ioreport *heron_ioreport_create(void) { return create(CFSTR("Energy Model"), NULL); }

heron_ioreport *heron_ioreport_create_cpu_states(void) {
    heron_ioreport *r = create(CFSTR("CPU Stats"), CFSTR("CPU Complex Performance States"));
    if (r && (!r->stateCount || !r->stateName || !r->stateResidency)) { heron_ioreport_destroy(r); return NULL; }
    return r;
}

void heron_ioreport_destroy(heron_ioreport *r) {
    if (!r) return;
    if (r->last) CFRelease(r->last);
    if (r->subbed) CFRelease(r->subbed);
    if (r->sub) CFRelease((CFTypeRef)r->sub);
    if (r->lib) dlclose(r->lib);
    free(r);
}

/// A new sample's delta since the previous one (NULL on the first call). The caller releases it.
static CFDictionaryRef take_delta(heron_ioreport *r) {
    CFDictionaryRef now = r->createSamples(r->sub, r->subbed, NULL);
    if (!now) return NULL;
    if (!r->last) { r->last = now; return NULL; }
    CFDictionaryRef delta = r->createDelta(r->last, now, NULL);
    CFRelease(r->last);
    r->last = now;
    return delta;
}

int heron_ioreport_sample_states(heron_ioreport *r, heron_state_channel *out, int max) {
    if (!r || !r->stateCount) return 0;
    CFDictionaryRef delta = take_delta(r);
    if (!delta) return 0;
    int count = 0;
    CFArrayRef items = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (items) {
        CFIndex n = CFArrayGetCount(items);
        for (CFIndex i = 0; i < n && count < max; i++) {
            CFDictionaryRef ch = CFArrayGetValueAtIndex(items, i);
            CFStringRef name = r->getName(ch);
            if (!name) continue;
            heron_state_channel *o = &out[count];
            memset(o, 0, sizeof(*o));
            CFStringGetCString(name, o->channel, sizeof(o->channel), kCFStringEncodingUTF8);
            int32_t states = r->stateCount(ch);
            if (states < 0) states = 0;
            if (states > HERON_MAX_STATES) states = HERON_MAX_STATES;
            for (int32_t s = 0; s < states; s++) {
                CFStringRef stateName = r->stateName(ch, s);
                if (stateName) CFStringGetCString(stateName, o->names[s], sizeof(o->names[s]), kCFStringEncodingUTF8);
                o->residency[s] = r->stateResidency(ch, s);
            }
            o->count = states;
            count++;
        }
    }
    CFRelease(delta);
    return count;
}

int heron_ioreport_sample(heron_ioreport *r, heron_energy_channel *out, int max) {
    if (!r) return 0;
    CFDictionaryRef delta = take_delta(r);
    if (!delta) return 0;

    int count = 0;
    CFArrayRef items = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    if (items) {
        CFIndex n = CFArrayGetCount(items);
        for (CFIndex i = 0; i < n && count < max; i++) {
            CFDictionaryRef ch = CFArrayGetValueAtIndex(items, i);
            CFStringRef g = r->getGroup(ch), name = r->getName(ch), unit = r->getUnit(ch);
            if (!g || !name) continue;
            heron_energy_channel *o = &out[count];
            memset(o, 0, sizeof(*o));
            CFStringGetCString(g, o->group, sizeof(o->group), kCFStringEncodingUTF8);
            CFStringGetCString(name, o->channel, sizeof(o->channel), kCFStringEncodingUTF8);
            if (unit) CFStringGetCString(unit, o->unit, sizeof(o->unit), kCFStringEncodingUTF8);
            o->value = r->getInt(ch, 0);
            count++;
        }
    }
    CFRelease(delta);
    return count;
}
