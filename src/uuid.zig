const std = @import("std");

/// Length of the lowercase dash-form UUID string (no NUL).
pub const len: usize = 36;

/// Process-global registry of every UUID handed out ("issued") or claimed
/// by a restored tab/pane. generate() re-rolls until the value is unseen,
/// so within one seance process no two terminals ever share a UUID — even
/// across windows — and a restored session.json can't smuggle a duplicate
/// identity in. All callers run on the GTK main thread, hence no locking.
/// Bounded: once max_tracked ids are recorded, older ones fall out of the
/// duplicate check (CSPRNG v4 collisions remain ~2^-122 regardless).
const max_tracked: usize = 4096;
var tracked: [max_tracked][len]u8 = undefined;
var n_tracked: usize = 0;

fn isSeen(id: *const [len]u8) bool {
    const items = tracked[0..@min(n_tracked, max_tracked)];
    for (items) |*t| {
        if (std.mem.eql(u8, t, id)) return true;
    }
    return false;
}

/// Record id as taken (no-op if already known).
pub fn record(id: *const [len]u8) void {
    if (isSeen(id)) return;
    if (n_tracked < max_tracked) {
        tracked[n_tracked] = id.*;
        n_tracked += 1;
    }
}

/// Adopt an externally-supplied id (session restore). Returns false when
/// the id collides with one already known to this process — the caller
/// must then mint a fresh one instead.
pub fn claim(id: *const [len]u8) bool {
    if (isSeen(id)) return false;
    record(id);
    return true;
}

/// Mint an RFC-4122 version-4 UUID (36 lowercase hex chars with dashes)
/// that is not already in the registry. Records it as issued.
pub fn generate(buf: *[len]u8) void {
    while (true) {
        var raw: [16]u8 = undefined;
        std.crypto.random.bytes(&raw);
        raw[6] = (raw[6] & 0x0f) | 0x40; // version 4
        raw[8] = (raw[8] & 0x3f) | 0x80; // variant 1

        const groups = [5]struct { off: usize, count: usize }{
            .{ .off = 0, .count = 4 },
            .{ .off = 4, .count = 2 },
            .{ .off = 6, .count = 2 },
            .{ .off = 8, .count = 2 },
            .{ .off = 10, .count = 6 },
        };

        var pos: usize = 0;
        for (groups, 0..) |g, i| {
            if (i > 0) {
                buf[pos] = '-';
                pos += 1;
            }
            for (raw[g.off .. g.off + g.count]) |b| {
                buf[pos] = hexDigit(b >> 4);
                buf[pos + 1] = hexDigit(b & 0x0f);
                pos += 2;
            }
        }

        if (!isSeen(buf)) break;
    }
    record(buf);
}

fn hexDigit(n: u8) u8 {
    return if (n < 10) '0' + n else 'a' + (n - 10);
}

const testing = std.testing;

test "generate: produces 36-char v4 uuid, distinct calls differ" {
    var a: [len]u8 = undefined;
    var b: [len]u8 = undefined;
    generate(&a);
    generate(&b);
    try testing.expectEqual(@as(u8, '4'), a[14]);
    try testing.expectEqualSlices(u8, "-", a[8..9]);
    try testing.expectEqualSlices(u8, "-", a[13..14]);
    try testing.expectEqualSlices(u8, "-", a[18..19]);
    try testing.expectEqualSlices(u8, "-", a[23..24]);
    try testing.expect(!std.mem.eql(u8, &a, &b));
    for (a) |ch| {
        try testing.expect(std.ascii.isHexDigit(ch) or ch == '-');
    }
}

test "claim: rejects duplicate ids, accepts fresh ones" {
    var id: [len]u8 = undefined;
    generate(&id);
    try testing.expect(!claim(&id)); // already recorded by generate
    const fresh = "0f8fad5b-d9cb-469f-a165-70867728950e";
    var copy: [len]u8 = undefined;
    @memcpy(&copy, fresh[0..len]);
    try testing.expect(claim(&copy));
    try testing.expect(!claim(&copy));
}
