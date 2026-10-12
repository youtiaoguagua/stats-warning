// SMC ABI and protocol informed by Stats (MIT), see THIRD_PARTY_NOTICES.md.
#include "SMCBridge.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SWVersion;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } SWLimit;
typedef struct { uint32_t size, type; uint8_t attributes; } SWKeyInfo;
typedef struct {
    uint32_t key;
    SWVersion version;
    SWLimit limit;
    SWKeyInfo info;
    uint8_t result, status, command;
    uint32_t index;
    uint8_t bytes[32];
} SWKeyData;
_Static_assert(sizeof(SWKeyData) == 80, "SMC ABI size mismatch");
_Static_assert(offsetof(SWKeyData, result) == 40, "SMC ABI result offset mismatch");
_Static_assert(offsetof(SWKeyData, bytes) == 48, "SMC ABI payload offset mismatch");

struct SWConnection {
    io_connect_t handle;
    struct { uint32_t key; SWKeyInfo info; } cache[512];
    size_t cacheCount;
};

static uint32_t code(const char *key) {
    return (uint32_t)(uint8_t)key[0] << 24 | (uint32_t)(uint8_t)key[1] << 16 |
           (uint32_t)(uint8_t)key[2] << 8 | (uint8_t)key[3];
}
static void string(uint32_t value, char output[5]) {
    for (int i = 0; i < 4; i++) output[i] = (char)(value >> (24 - 8 * i));
    output[4] = 0;
}
static int32_t call(SWConnection *connection, SWKeyData *input, SWKeyData *output) {
    if (!connection) return kIOReturnNotOpen;
    size_t size = sizeof(*output);
    kern_return_t result = IOConnectCallStructMethod(connection->handle, 2, input, sizeof(*input), output, &size);
    if (result != kIOReturnSuccess) return result;
    if (size != sizeof(*output)) return kIOReturnUnderrun;
    if (output->result == 0x84) return kIOReturnNotFound;
    return output->result == 0 ? kIOReturnSuccess : kIOReturnError;
}

SWConnection *sw_smc_open(int32_t *error) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) { *error = kIOReturnNotFound; return NULL; }
    SWConnection *connection = calloc(1, sizeof(*connection));
    if (!connection) { IOObjectRelease(service); *error = kIOReturnNoMemory; return NULL; }
    *error = IOServiceOpen(service, mach_task_self(), 0, &connection->handle);
    IOObjectRelease(service);
    if (*error != kIOReturnSuccess) { free(connection); return NULL; }
    return connection;
}
void sw_smc_close(SWConnection *connection) {
    if (!connection) return;
    IOServiceClose(connection->handle);
    free(connection);
}
int32_t sw_smc_read(SWConnection *connection, const char key[5], char type[5], uint8_t bytes[32], uint32_t *size) {
    if (!connection || !key || strlen(key) != 4) return kIOReturnBadArgument;
    SWKeyData input = {0}, output = {0};
    input.key = code(key);
    SWKeyInfo info = {0};
    size_t slot = 0;
    for (; slot < connection->cacheCount; slot++) {
        if (connection->cache[slot].key == input.key) { info = connection->cache[slot].info; break; }
    }
    if (!info.size) {
        input.command = 9;
        int32_t result = call(connection, &input, &output);
        if (result) return result;
        info = output.info;
    }
    if (info.size == 0 || info.size > 32) return kIOReturnBadArgument;
    input.info.size = info.size;
    input.command = 5;
    memset(&output, 0, sizeof(output));
    int32_t result = call(connection, &input, &output);
    if (result) {
        if (slot < connection->cacheCount) connection->cache[slot] = connection->cache[--connection->cacheCount];
        return result;
    }
    if (slot == connection->cacheCount && slot < 512) {
        connection->cache[slot].key = input.key;
        connection->cache[slot].info = info;
        connection->cacheCount++;
    }
    string(info.type, type);
    memcpy(bytes, output.bytes, info.size);
    *size = info.size;
    return kIOReturnSuccess;
}
int32_t sw_smc_key_count(SWConnection *connection, uint32_t *count) {
    char type[5] = {0}; uint8_t bytes[32] = {0}; uint32_t size = 0;
    int32_t result = sw_smc_read(connection, "#KEY", type, bytes, &size);
    if (result) return result;
    if (size != 4 || strcmp(type, "ui32") != 0) return kIOReturnBadArgument;
    *count = (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 | (uint32_t)bytes[2] << 8 | bytes[3];
    return kIOReturnSuccess;
}
int32_t sw_smc_key_at(SWConnection *connection, uint32_t index, char key[5]) {
    SWKeyData input = {0}, output = {0};
    input.command = 8; input.index = index;
    int32_t result = call(connection, &input, &output);
    if (!result) string(output.key, key);
    return result;
}
