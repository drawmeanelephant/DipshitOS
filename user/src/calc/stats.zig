//! calc/stats.zig — M24 K16 statistics mode for CALC.BIN.
//!
//! Bounded sample store ([100]f64 per the card) with n/sum/mean/median/
//! population-std-dev/min/max. Median sorts a copy — the stored order is
//! preserved. Pure logic, no heap, no syscalls.

const std = @import("std");

pub const max_samples: usize = 100;

pub const StatsError = error{
    Empty,
};

pub const Stats = struct {
    values: [max_samples]f64 = [_]f64{0} ** max_samples,
    len: usize = 0,

    pub const Result = struct {
        n: usize,
        sum: f64,
        mean: f64,
        median: f64,
        std_dev: f64, // population
        min: f64,
        max: f64,
    };

    pub fn clear(self: *Stats) void {
        self.len = 0;
    }

    /// Parse a comma-separated list into the store (replaces content).
    /// Returns error.TooMany when the list exceeds max_samples.
    pub fn parse_list(self: *Stats, text: []const u8) error{ TooMany, Empty }!void {
        self.len = 0;
        var any = false;
        var it = std.mem.splitScalar(u8, text, ',');
        while (it.next()) |piece_raw| {
            const piece = std.mem.trim(u8, piece_raw, " \t");
            if (piece.len == 0) continue;
            const v = std.fmt.parseFloat(f64, piece) catch continue;
            if (self.len >= max_samples) return error.TooMany;
            self.values[self.len] = v;
            self.len += 1;
            any = true;
        }
        if (!any) return error.Empty;
    }

    /// Sort a snapshot ascending (insertion sort — n ≤ 100).
    fn sorted(self: *const Stats, buf: *[max_samples]f64) void {
        @memcpy(buf[0..self.len], self.values[0..self.len]);
        const n = self.len;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const key = buf[i];
            var j = i;
            while (j > 0 and buf[j - 1] > key) : (j -= 1) {
                buf[j] = buf[j - 1];
            }
            buf[j] = key;
        }
    }

    pub fn compute(self: *const Stats) StatsError!Result {
        if (self.len == 0) return error.Empty;
        const n = self.len;
        const nf: f64 = @floatFromInt(n);

        var sum: f64 = 0;
        for (self.values[0..n]) |v| sum += v;
        const mean = sum / nf;

        var snap: [max_samples]f64 = undefined;
        self.sorted(&snap);
        const median = if (n % 2 == 1)
            snap[n / 2]
        else
            (snap[n / 2 - 1] + snap[n / 2]) / 2.0;

        var ss: f64 = 0;
        for (self.values[0..n]) |v| {
            const d = v - mean;
            ss += d * d;
        }
        const std_dev = @sqrt(ss / nf);

        return .{
            .n = n,
            .sum = sum,
            .mean = mean,
            .median = median,
            .std_dev = std_dev,
            .min = snap[0],
            .max = snap[n - 1],
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "stats: issue case [1,2,3,4,5]" {
    var s = Stats{};
    try s.parse_list("1,2,3,4,5");
    const r = try s.compute();
    try std.testing.expectEqual(@as(usize, 5), r.n);
    try std.testing.expectApproxEqAbs(@as(f64, 3), r.mean, 1e-12); // mean = 3
    try std.testing.expectApproxEqAbs(@as(f64, 3), r.median, 1e-12); // median = 3
    try std.testing.expectEqual(@as(f64, 1), r.min); // min = 1
    try std.testing.expectEqual(@as(f64, 5), r.max); // max = 5
    try std.testing.expectApproxEqAbs(@as(f64, 15), r.sum, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1.4142135623730951), r.std_dev, 1e-9);
}

test "stats: even-count median averages the middle pair" {
    var s = Stats{};
    try s.parse_list("4, 1, 3,2");
    const r = try s.compute();
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), r.median, 1e-12);
}

test "stats: bounds and errors" {
    var s = Stats{};
    try std.testing.expectError(error.Empty, s.compute());
    try std.testing.expectError(error.Empty, s.parse_list(""));

    // 101 samples refused honestly at 100: build a 150-item list
    var buf: [512]u8 = undefined;
    var pos: usize = 0;
    var i: usize = 0;
    while (i < 150 and pos + 5 < buf.len) : (i += 1) {
        const piece = std.fmt.bufPrint(buf[pos..], "{d},", .{i}) catch break;
        pos += piece.len;
    }
    var big = Stats{};
    try std.testing.expectError(error.TooMany, big.parse_list(buf[0..pos]));
}
