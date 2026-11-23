// SMC access, the same structure the open-source smcFanControl and Stats use.
// The kernel expects this exact struct layout, so it must not be reordered.
#include "CSystem.h"
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

typedef struct {
    char major, minor, build, reserved;
    uint16_t release;
} smc_vers;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} smc_plimit;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    char dataAttributes;
} smc_keyinfo;

typedef struct {
    uint32_t key;
    smc_vers vers;
    smc_plimit pLimitData;
    smc_keyinfo keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    uint8_t bytes[32];
} smc_keydata;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint32_t)(uint8_t)s[3];
}

static void unfourcc(uint32_t v, char out[5]) {
    out[0] = (char)(v >> 24); out[1] = (char)(v >> 16); out[2] = (char)(v >> 8); out[3] = (char)v; out[4] = 0;
}

static bool call(io_connect_t conn, smc_keydata *in, smc_keydata *out) {
    size_t outSize = sizeof(smc_keydata);
    kern_return_t kr = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(smc_keydata), out, &outSize);
    return kr == KERN_SUCCESS && out->result == 0;
}

io_connect_t heron_smc_open(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    io_connect_t conn = 0;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    return kr == KERN_SUCCESS ? conn : 0;
}

void heron_smc_close(io_connect_t conn) {
    if (conn) IOServiceClose(conn);
}

static bool keyinfo(io_connect_t conn, uint32_t key, smc_keyinfo *info) {
    smc_keydata in = {0}, out = {0};
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (!call(conn, &in, &out)) return false;
    *info = out.keyInfo;
    return true;
}

bool heron_smc_key_info(io_connect_t conn, const char *key, char type[5], uint32_t *size) {
    if (!conn || strlen(key) != 4) return false;
    smc_keyinfo info;
    if (!keyinfo(conn, fourcc(key), &info)) return false;
    unfourcc(info.dataType, type);
    *size = info.dataSize;
    return true;
}

bool heron_smc_read_sized(io_connect_t conn, const char *key, uint32_t dataSize, uint8_t bytes[32]) {
    if (!conn || strlen(key) != 4) return false;
    smc_keydata in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    if (!call(conn, &in, &out)) return false;
    memcpy(bytes, out.bytes, dataSize > 32 ? 32 : dataSize);
    return true;
}

bool heron_smc_read(io_connect_t conn, const char *key, char type[5], uint8_t bytes[32], uint32_t *size) {
    uint32_t dataSize = 0;
    if (!heron_smc_key_info(conn, key, type, &dataSize)) return false;
    if (!heron_smc_read_sized(conn, key, dataSize, bytes)) return false;
    *size = dataSize > 32 ? 32 : dataSize;
    return true;
}

uint32_t heron_smc_key_count(io_connect_t conn) {
    char type[5]; uint8_t b[32]; uint32_t n = 0;
    if (!heron_smc_read(conn, "#KEY", type, b, &n) || n < 4) return 0;
    return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
}

bool heron_smc_key_at(io_connect_t conn, uint32_t index, char key[5]) {
    smc_keydata in = {0}, out = {0};
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    if (!call(conn, &in, &out)) return false;
    unfourcc(out.key, key);
    return true;
}
