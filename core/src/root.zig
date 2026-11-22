//! Seance core: terminal and session logic shared by the iOS and Android apps.
//! Pure logic only: no I/O, no clocks, no threads. See ADR 0012.

const std = @import("std");
const reconnect = @import("reconnect.zig");
const engine = @import("engine.zig");

pub const abi_version: u32 = 1;

export fn sc_abi_version() u32 {
    return abi_version;
}

/// Caller-owned reconnect policy state (see reconnect.zig).
pub const ScReconnectPolicy = reconnect.Policy;

/// Initializes `policy`. Returns 0 on success, or -1 when `max_attempts` is
/// outside 1...10 or `backoff` is not 0 (fast), 1 (balanced) or 2 (conservative).
export fn sc_reconnect_init(policy: *ScReconnectPolicy, enabled: bool, max_attempts: u32, backoff: u8) i32 {
    const kind = std.enums.fromInt(reconnect.Backoff, backoff) orelse return -1;
    policy.* = reconnect.Policy.init(enabled, max_attempts, kind) catch return -1;
    return 0;
}

/// Changes settings while keeping attempts and the retry window. Same return
/// codes as sc_reconnect_init().
export fn sc_reconnect_configure(policy: *ScReconnectPolicy, enabled: bool, max_attempts: u32, backoff: u8) i32 {
    const kind = std.enums.fromInt(reconnect.Backoff, backoff) orelse return -1;
    policy.configure(enabled, max_attempts, kind) catch return -1;
    return 0;
}

/// Writes the delay in milliseconds before the next attempt to `out_delay_ms`
/// and returns true, or returns false when no more attempts are allowed.
export fn sc_reconnect_next_delay(policy: *const ScReconnectPolicy, now_ms: i64, out_delay_ms: *i64) bool {
    const delay = policy.nextDelay(now_ms) orelse return false;
    out_delay_ms.* = delay;
    return true;
}

export fn sc_reconnect_begin_attempt(policy: *ScReconnectPolicy, now_ms: i64) bool {
    return policy.beginAttempt(now_ms);
}

export fn sc_reconnect_reset(policy: *ScReconnectPolicy) void {
    policy.reset();
}

export fn sc_reconnect_pause(policy: *ScReconnectPolicy, now_ms: i64) void {
    policy.pause(now_ms);
}

export fn sc_reconnect_resume(policy: *ScReconnectPolicy, now_ms: i64) void {
    policy.resumeAt(now_ms);
}

export fn sc_reconnect_attempt_count(policy: *const ScReconnectPolicy) u32 {
    return policy.attempts;
}

export fn sc_reconnect_window_ms(policy: *const ScReconnectPolicy) i64 {
    return policy.retryWindowMs();
}

comptime {
    _ = @import("engine_abi.zig");
    // JNI exports are for Android and the host-side JVM tests, not iOS.
    if (@import("builtin").os.tag != .ios) _ = @import("jni.zig");
}

test {
    _ = reconnect;
    _ = engine;
    _ = @import("engine_tests.zig");
    _ = @import("engine_abi.zig");
    _ = @import("jni.zig");
}

test "abi version is stable" {
    try std.testing.expectEqual(@as(u32, 1), sc_abi_version());
}

test "c abi mirrors the policy" {
    var policy: ScReconnectPolicy = undefined;
    try std.testing.expectEqual(@as(i32, 0), sc_reconnect_init(&policy, true, 5, 1));
    var delay: i64 = -1;
    try std.testing.expect(sc_reconnect_next_delay(&policy, 0, &delay));
    try std.testing.expectEqual(@as(i64, 0), delay);
    try std.testing.expect(sc_reconnect_begin_attempt(&policy, 0));
    try std.testing.expectEqual(@as(u32, 1), sc_reconnect_attempt_count(&policy));
    try std.testing.expectEqual(@as(i32, -1), sc_reconnect_init(&policy, true, 11, 1));
    try std.testing.expectEqual(@as(i32, -1), sc_reconnect_init(&policy, true, 5, 9));
}
