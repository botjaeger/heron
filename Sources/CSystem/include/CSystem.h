// CSystem — thin C wrappers around macOS APIs that have no public Swift interface.
//
//   * SMC (System Management Controller): fan speeds and many temperature sensors.
//   * IOHIDEventSystem: temperature sensors exposed through the HID layer (private API).
//   * IOReport: energy counters used to compute CPU / GPU / ANE / DRAM power (private API),
//     and the CPU clusters' performance-state residencies (their clock speed).
//
// Everything here is read-only: Heron never writes to the SMC.
#ifndef CSYSTEM_H
#define CSYSTEM_H

#include <stdint.h>
#include <stdbool.h>
#include <IOKit/IOKitLib.h>

// MARK: SMC

/// Opens a connection to the AppleSMC kernel service. Returns 0 on failure.
io_connect_t heron_smc_open(void);
void heron_smc_close(io_connect_t conn);

/// Reads one SMC key (4 characters, e.g. "F0Ac").
/// On success fills `type` (4 chars + NUL), `bytes` (up to 32) and `size`, and returns true.
bool heron_smc_read(io_connect_t conn, const char *key, char type[5], uint8_t bytes[32], uint32_t *size);

/// The two halves of heron_smc_read, so callers can cache a key's type and size (they never
/// change) and read the value with one kernel call instead of two.
bool heron_smc_key_info(io_connect_t conn, const char *key, char type[5], uint32_t *size);
bool heron_smc_read_sized(io_connect_t conn, const char *key, uint32_t dataSize, uint8_t bytes[32]);

/// Number of keys the SMC knows about.
uint32_t heron_smc_key_count(io_connect_t conn);

/// Name of the key at `index` (0-based), written into `key` (4 chars + NUL).
bool heron_smc_key_at(io_connect_t conn, uint32_t index, char key[5]);

// MARK: HID temperature sensors

typedef struct {
    char name[64];
    double celsius;
} heron_hid_temp;

/// Reads every HID temperature sensor. Returns how many entries were written (<= max).
int heron_hid_temperatures(heron_hid_temp *out, int max);

// MARK: IOReport energy

typedef struct heron_ioreport heron_ioreport;

typedef struct {
    char group[64];
    char channel[64];
    char unit[16];
    int64_t value;      // energy since the previous sample, in `unit`
} heron_energy_channel;

/// Subscribes to the "Energy Model" IOReport group. Returns NULL if IOReport is unavailable.
heron_ioreport *heron_ioreport_create(void);
void heron_ioreport_destroy(heron_ioreport *r);

/// Takes a sample and writes the delta since the last call. The first call only primes and returns 0.
int heron_ioreport_sample(heron_ioreport *r, heron_energy_channel *out, int max);

// MARK: IOReport performance states

#define HERON_MAX_STATES 32

typedef struct {
    char channel[64];
    int32_t count;                              // states written (<= HERON_MAX_STATES)
    char names[HERON_MAX_STATES][16];           // e.g. "IDLE", "V0P5"
    int64_t residency[HERON_MAX_STATES];        // ticks in each state since the previous sample
} heron_state_channel;

/// Subscribes to the "CPU Stats" › "CPU Complex Performance States" IOReport channels (how long
/// each CPU cluster spent at each frequency step). Returns NULL if IOReport is unavailable.
/// Free with heron_ioreport_destroy.
heron_ioreport *heron_ioreport_create_cpu_states(void);

/// Like heron_ioreport_sample, for a subscription made by heron_ioreport_create_cpu_states.
int heron_ioreport_sample_states(heron_ioreport *r, heron_state_channel *out, int max);

#endif
