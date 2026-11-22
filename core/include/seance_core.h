#ifndef SEANCE_CORE_H
#define SEANCE_CORE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Version of this C ABI. Bumped on any incompatible change. */
uint32_t sc_abi_version(void);

/* Reconnect policy. The state is caller-owned; treat it as opaque and
 * initialize it with sc_reconnect_init(). Times are milliseconds from any
 * monotonic clock. */
typedef struct {
  bool enabled;
  uint32_t max_attempts;
  uint8_t backoff;
  int64_t started_at;
  uint32_t attempts;
  int64_t paused_at;
  int64_t paused_duration;
} ScReconnectPolicy;

enum { SC_BACKOFF_FAST = 0, SC_BACKOFF_BALANCED = 1, SC_BACKOFF_CONSERVATIVE = 2 };

/** Returns 0 on success, -1 if max_attempts is outside 1...10 or backoff is unknown. */
int32_t sc_reconnect_init(ScReconnectPolicy* policy, bool enabled, uint32_t max_attempts, uint8_t backoff);
/** Changes settings while keeping attempts and the retry window. Same return codes as init. */
int32_t sc_reconnect_configure(ScReconnectPolicy* policy, bool enabled, uint32_t max_attempts, uint8_t backoff);
/** Writes the delay before the next attempt and returns true, or returns false when no attempts remain. */
bool sc_reconnect_next_delay(const ScReconnectPolicy* policy, int64_t now_ms, int64_t* out_delay_ms);
bool sc_reconnect_begin_attempt(ScReconnectPolicy* policy, int64_t now_ms);
void sc_reconnect_reset(ScReconnectPolicy* policy);
void sc_reconnect_pause(ScReconnectPolicy* policy, int64_t now_ms);
void sc_reconnect_resume(ScReconnectPolicy* policy, int64_t now_ms);
uint32_t sc_reconnect_attempt_count(const ScReconnectPolicy* policy);
int64_t sc_reconnect_window_ms(const ScReconnectPolicy* policy);

#ifdef __cplusplus
}
#endif

#endif
