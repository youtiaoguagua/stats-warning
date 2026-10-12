#ifndef SMC_BRIDGE_H
#define SMC_BRIDGE_H
#include <stdint.h>

// A deliberately read-only API. No fan control or SMC write commands are exposed.
typedef struct SWConnection SWConnection;
SWConnection *sw_smc_open(int32_t *error);
void sw_smc_close(SWConnection *connection);
int32_t sw_smc_key_count(SWConnection *connection, uint32_t *count);
int32_t sw_smc_key_at(SWConnection *connection, uint32_t index, char key[5]);
int32_t sw_smc_read(SWConnection *connection, const char key[5], char type[5], uint8_t bytes[32], uint32_t *size);
#endif
