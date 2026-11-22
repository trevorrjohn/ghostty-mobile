//! JNI exports for the Android app (class `dev.ghostty.connect.terminal.bridge.SeanceCore`).
//!
//! Only primitive JNI types are used, so no `jni.h` is needed: `JNIEnv*` and
//! `jclass` are passed through as opaque pointers. Reconnect policies live in a
//! fixed pool and Kotlin holds a 1-based handle (0 means failure), which keeps
//! the core allocation-free. A handle must not be used concurrently from
//! several threads.

const std = @import("std");
const reconnect = @import("reconnect.zig");

const Env = ?*anyopaque;
const Class = ?*anyopaque;

const pool_size = 256;
var policies: [pool_size]reconnect.Policy = undefined;
var in_use: [pool_size]std.atomic.Value(bool) = @splat(std.atomic.Value(bool).init(false));

fn slot(handle: i64) ?*reconnect.Policy {
    if (handle < 1 or handle > pool_size) return null;
    const index: usize = @intCast(handle - 1);
    if (!in_use[index].load(.acquire)) return null;
    return &policies[index];
}

export fn Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectCreate(
    _: Env,
    _: Class,
    enabled: u8,
    max_attempts: i32,
    backoff: i32,
) i64 {
    if (max_attempts < 0 or backoff < 0 or backoff > 255) return 0;
    const kind = std.enums.fromInt(reconnect.Backoff, @as(u8, @intCast(backoff))) orelse return 0;
    const policy = reconnect.Policy.init(enabled != 0, @intCast(max_attempts), kind) catch return 0;
    for (&in_use, 0..) |*flag, index| {
        if (flag.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            policies[index] = policy;
            return @intCast(index + 1);
        }
    }
    return 0;
}

export fn Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectFree(_: Env, _: Class, handle: i64) void {
    if (slot(handle) == null) return;
    in_use[@intCast(handle - 1)].store(false, .release);
}

/// Returns the delay in milliseconds, or -1 when no more attempts are allowed.
export fn Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectNextDelay(_: Env, _: Class, handle: i64, now: i64) i64 {
    const policy = slot(handle) orelse return -1;
    return policy.nextDelay(now) orelse -1;
}

export fn Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectBeginAttempt(_: Env, _: Class, handle: i64, now: i64) u8 {
    const policy = slot(handle) orelse return 0;
    return @intFromBool(policy.beginAttempt(now));
}

export fn Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectReset(_: Env, _: Class, handle: i64) void {
    if (slot(handle)) |policy| policy.reset();
}

export fn Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectPause(_: Env, _: Class, handle: i64, now: i64) void {
    if (slot(handle)) |policy| policy.pause(now);
}

export fn Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectResume(_: Env, _: Class, handle: i64, now: i64) void {
    if (slot(handle)) |policy| policy.resumeAt(now);
}

export fn Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectAttemptCount(_: Env, _: Class, handle: i64) i32 {
    const policy = slot(handle) orelse return 0;
    return @intCast(policy.attempts);
}

export fn Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectWindowMs(_: Env, _: Class, handle: i64) i64 {
    const policy = slot(handle) orelse return 0;
    return policy.retryWindowMs();
}

test "pool hands out distinct handles and rejects stale ones" {
    const a = Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectCreate(null, null, 1, 5, 1);
    const b = Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectCreate(null, null, 1, 5, 1);
    try std.testing.expect(a > 0 and b > 0 and a != b);
    try std.testing.expectEqual(@as(i64, 0), Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectNextDelay(null, null, a, 0));
    Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectFree(null, null, a);
    try std.testing.expectEqual(@as(i64, -1), Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectNextDelay(null, null, a, 0));
    Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectFree(null, null, b);
    try std.testing.expectEqual(@as(i64, 0), Java_dev_ghostty_connect_terminal_bridge_SeanceCore_nativeReconnectCreate(null, null, 1, 0, 1));
}
