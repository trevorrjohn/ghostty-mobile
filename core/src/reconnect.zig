//! Reconnect policy: bounded, deterministic backoff inside a retry window
//! that can be paused (for example while the app is backgrounded).
//! Pure state machine; the caller supplies `now` in milliseconds from any
//! monotonic clock.

const std = @import("std");

pub const min_attempts: u32 = 1;
pub const max_attempts: u32 = 10;
pub const default_attempts: u32 = 5;

const minimum_window_ms: i64 = 120_000;
const attempt_allowance_ms: i64 = 30_000;

pub const Backoff = enum(u8) {
    fast = 0,
    balanced = 1,
    conservative = 2,

    pub fn delays(self: Backoff) *const [10]i64 {
        return switch (self) {
            .fast => &.{ 0, 1_000, 2_000, 3_000, 5_000, 8_000, 13_000, 20_000, 30_000, 30_000 },
            .balanced => &.{ 0, 2_000, 5_000, 10_000, 20_000, 30_000, 30_000, 30_000, 30_000, 30_000 },
            .conservative => &.{ 0, 5_000, 15_000, 30_000, 60_000, 60_000, 60_000, 60_000, 60_000, 60_000 },
        };
    }
};

pub const Error = error{InvalidAttempts};

pub const Policy = extern struct {
    enabled: bool = true,
    max_attempts: u32 = default_attempts,
    backoff: Backoff = .balanced,
    started_at: i64 = -1,
    attempts: u32 = 0,
    paused_at: i64 = -1,
    paused_duration: i64 = 0,

    pub fn init(enabled: bool, attempts: u32, backoff: Backoff) Error!Policy {
        if (attempts < min_attempts or attempts > max_attempts) return Error.InvalidAttempts;
        return .{ .enabled = enabled, .max_attempts = attempts, .backoff = backoff };
    }

    /// Applies new settings while keeping progress (attempts and window).
    pub fn configure(self: *Policy, enabled: bool, attempts: u32, backoff: Backoff) Error!void {
        if (attempts < min_attempts or attempts > max_attempts) return Error.InvalidAttempts;
        self.enabled = enabled;
        self.max_attempts = attempts;
        self.backoff = backoff;
    }

    pub fn retryWindowMs(self: *const Policy) i64 {
        var total: i64 = 0;
        for (self.backoff.delays()[0..self.max_attempts]) |delay| total += delay;
        return @max(minimum_window_ms, total + attempt_allowance_ms * @as(i64, self.max_attempts));
    }

    /// Delay in milliseconds before the next attempt, or null when no more
    /// attempts are allowed (disabled, exhausted, or the window has closed).
    pub fn nextDelay(self: *const Policy, now: i64) ?i64 {
        if (!self.enabled or self.attempts >= self.max_attempts) return null;
        const current_pause: i64 = if (self.paused_at >= 0) now - self.paused_at else 0;
        if (self.started_at >= 0 and now - self.started_at - self.paused_duration - current_pause > self.retryWindowMs()) return null;
        return self.backoff.delays()[self.attempts];
    }

    pub fn beginAttempt(self: *Policy, now: i64) bool {
        if (self.nextDelay(now) == null) return false;
        if (self.started_at < 0) self.started_at = now;
        self.attempts += 1;
        return true;
    }

    pub fn reset(self: *Policy) void {
        self.started_at = -1;
        self.attempts = 0;
        self.paused_at = -1;
        self.paused_duration = 0;
    }

    pub fn pause(self: *Policy, now: i64) void {
        if (self.started_at >= 0 and self.paused_at < 0) self.paused_at = now;
    }

    pub fn resumeAt(self: *Policy, now: i64) void {
        if (self.paused_at < 0) return;
        self.paused_duration += now - self.paused_at;
        self.paused_at = -1;
    }
};

test "retries use bounded deterministic backoff" {
    var policy = try Policy.init(true, default_attempts, .balanced);
    var now: i64 = 1_000;
    for (Backoff.balanced.delays()[0..5]) |delay| {
        try std.testing.expectEqual(@as(?i64, delay), policy.nextDelay(now));
        now += delay;
        try std.testing.expect(policy.beginAttempt(now));
    }
    try std.testing.expectEqual(@as(?i64, null), policy.nextDelay(now));
    try std.testing.expect(!policy.beginAttempt(now));
}

test "retry window does not reset without a successful connection" {
    var policy = try Policy.init(true, default_attempts, .balanced);
    try std.testing.expect(policy.beginAttempt(1_000));
    try std.testing.expectEqual(@as(?i64, null), policy.nextDelay(1_000 + policy.retryWindowMs() + 1));
}

test "paused time does not count against the retry window" {
    var policy = try Policy.init(true, default_attempts, .balanced);
    try std.testing.expect(policy.beginAttempt(0));
    policy.pause(10_000);
    const late = 10_000 + policy.retryWindowMs() * 3;
    try std.testing.expect(policy.nextDelay(late) != null);
    policy.resumeAt(late);
    try std.testing.expect(policy.nextDelay(late + 1_000) != null);
    try std.testing.expectEqual(@as(?i64, null), policy.nextDelay(late + policy.retryWindowMs() + 1));
}

test "reset clears attempts and window" {
    var policy = try Policy.init(true, 2, .fast);
    try std.testing.expect(policy.beginAttempt(0));
    try std.testing.expect(policy.beginAttempt(0));
    try std.testing.expect(!policy.beginAttempt(0));
    policy.reset();
    try std.testing.expect(policy.beginAttempt(0));
    try std.testing.expectEqual(@as(u32, 1), policy.attempts);
}

test "disabled policy never retries and attempts are range checked" {
    const policy = try Policy.init(false, 5, .balanced);
    try std.testing.expectEqual(@as(?i64, null), policy.nextDelay(0));
    try std.testing.expectError(Error.InvalidAttempts, Policy.init(true, 0, .balanced));
    try std.testing.expectError(Error.InvalidAttempts, Policy.init(true, 11, .balanced));
}

test "conservative backoff is slower than fast" {
    const fast = try Policy.init(true, 5, .fast);
    const slow = try Policy.init(true, 5, .conservative);
    try std.testing.expect(slow.retryWindowMs() >= fast.retryWindowMs());
}
