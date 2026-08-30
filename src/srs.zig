//! Pure SM-2 spaced-repetition math. Clock-free: due-date arithmetic happens
//! in SQL (CURRENT_DATE + interval_days).

const std = @import("std");

pub const State = struct {
    ease_factor: f64,
    interval_days: u32,
    repetitions: u32,

    /// State for an item that has never been reviewed.
    pub const fresh: State = .{ .ease_factor = 2.5, .interval_days = 0, .repetitions = 0 };
};

pub const mastered_interval_days = 21;

/// Classic SM-2. quality: 0-2 failed recall, 3 hard, 4 good, 5 easy.
pub fn apply(s: State, quality: u3) State {
    std.debug.assert(quality <= 5);
    const q: f64 = @floatFromInt(quality);
    const ef = @max(1.3, s.ease_factor + (0.1 - (5.0 - q) * (0.08 + (5.0 - q) * 0.02)));

    if (quality < 3) {
        return .{ .ease_factor = ef, .interval_days = 1, .repetitions = 0 };
    }
    const reps = s.repetitions + 1;
    const interval: u32 = switch (reps) {
        1 => 1,
        2 => 6,
        else => @intFromFloat(@round(@as(f64, @floatFromInt(s.interval_days)) * ef)),
    };
    return .{ .ease_factor = ef, .interval_days = interval, .repetitions = reps };
}

pub fn status(s: State, quality: u3) []const u8 {
    if (quality < 3) return "learning";
    if (s.interval_days >= mastered_interval_days) return "mastered";
    return "review";
}

test "first successful reviews follow 1, 6, round(6*ef)" {
    var s = State.fresh;
    s = apply(s, 5);
    try std.testing.expectEqual(@as(u32, 1), s.interval_days);
    try std.testing.expectEqual(@as(u32, 1), s.repetitions);

    s = apply(s, 5);
    try std.testing.expectEqual(@as(u32, 6), s.interval_days);

    const before_ef = s.ease_factor;
    s = apply(s, 5);
    const expected: u32 = @intFromFloat(@round(6.0 * (before_ef + 0.1)));
    try std.testing.expectEqual(expected, s.interval_days);
    try std.testing.expectEqual(@as(u32, 3), s.repetitions);
}

test "quality 5 raises ease, quality 3 lowers it" {
    const up = apply(State.fresh, 5);
    try std.testing.expect(up.ease_factor > 2.5);
    const down = apply(State.fresh, 3);
    try std.testing.expect(down.ease_factor < 2.5);
}

test "failed recall resets repetitions and interval" {
    var s = State.fresh;
    s = apply(s, 5);
    s = apply(s, 5);
    s = apply(s, 2);
    try std.testing.expectEqual(@as(u32, 0), s.repetitions);
    try std.testing.expectEqual(@as(u32, 1), s.interval_days);
    try std.testing.expect(s.ease_factor < 2.5);
}

test "ease factor never drops below 1.3" {
    var s = State.fresh;
    for (0..20) |_| s = apply(s, 0);
    try std.testing.expectEqual(@as(f64, 1.3), s.ease_factor);
}

test "quality 4 leaves the ease factor unchanged" {
    // SM-2's delta is 0.1 - (5-q)(0.08 + (5-q)*0.02); at q=4 that is exactly 0.
    const s = apply(State.fresh, 4);
    try std.testing.expectEqual(@as(f64, 2.5), s.ease_factor);
}

test "steady quality-4 reviews reach mastery" {
    var s = State.fresh;
    var reviews: u32 = 0;
    while (s.interval_days < mastered_interval_days) : (reviews += 1) {
        try std.testing.expect(reviews < 10); // must converge quickly
        s = apply(s, 4);
    }
    // 1, 6, 15, 38: mastered on the fourth successful review.
    try std.testing.expectEqual(@as(u32, 4), reviews);
    try std.testing.expectEqualStrings("mastered", status(s, 4));
}

test "interval growth is monotonic while succeeding" {
    var s = apply(State.fresh, 3);
    for (0..8) |_| {
        const next = apply(s, 3);
        try std.testing.expect(next.interval_days >= s.interval_days);
        try std.testing.expect(next.ease_factor >= 1.3);
        s = next;
    }
}

test "status derivation" {
    try std.testing.expectEqualStrings("learning", status(.{ .ease_factor = 2.5, .interval_days = 30, .repetitions = 5 }, 2));
    try std.testing.expectEqualStrings("review", status(.{ .ease_factor = 2.5, .interval_days = 6, .repetitions = 2 }, 4));
    try std.testing.expectEqualStrings("mastered", status(.{ .ease_factor = 2.5, .interval_days = 21, .repetitions = 4 }, 4));
}
