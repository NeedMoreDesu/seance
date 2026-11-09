//! zmx integration primitives — pure, no GTK/ghostty, unit-testable.
//!
//! Session naming: each terminal (Pane) mints a UUID (uuid.zig) that is
//! persisted in session.json; its zmx session is "seance-<pane-uuid>".
//! Tabs additionally own a UUID used only as the grouping id for lifecycle
//! hooks and session labels.
//!
//! Kill policy (when [behavior] zmx-attach = true):
//!   - explicit terminal close (pane removed, tab closed, split closed)
//!     → kill that terminal's session
//!   - window closed while other windows remain → kill all its panes
//!   - WHOLE-APP quit → kill NOTHING (sessions survive for re-attach)

const std = @import("std");
const uuid = @import("uuid.zig");

pub const session_prefix = "seance-";

/// "seance-<pane-uuid>" into buf; returns null if buf is too small.
pub fn sessionName(pane_uuid: *const [uuid.len]u8, buf: []u8) ?[]const u8 {
    if (buf.len < session_prefix.len + uuid.len) return null;
    return std.fmt.bufPrint(buf, "{s}{s}", .{ session_prefix, pane_uuid[0..] }) catch null;
}

/// Max length of a single generated kill command (the spawner caps commands
/// at 1024 chars; leave headroom and chunk larger inputs across commands).
pub const max_cmd_len = 1000;

/// Kill-one-each command template. The pane-UUID list is passed out-of-band
/// via SEANCE_PANE_UUIDS (space-separated) so a 200-pane tab still fits in
/// the command buffer and the envp size limit protects the tail case.
pub const kill_cmd_env =
    \\for u in $SEANCE_PANE_UUIDS; do zmx kill --force "seance-$u" & done; wait; exit 0
;

fn isValidUuidToken(tok: []const u8) bool {
    if (tok.len != uuid.len) return false;
    for (tok) |ch| {
        if (!std.ascii.isHex(ch) and ch != '-') return false;
    }
    return true;
}

/// Format the valid UUIDs from `list` back into a normalized
/// space-separated buffer (corrupt tokens dropped, single spaces).
/// Returns the normalized slice of buf, or null on overflow.
pub fn normalizeUuidList(list: []const u8, buf: []u8) ?[]const u8 {
    var pos: usize = 0;
    var it = std.mem.tokenizeScalar(u8, list, ' ');
    var first = true;
    while (it.next()) |tok| {
        if (!isValidUuidToken(tok)) continue;
        const need: usize = (if (first) @as(usize, 0) else 1) + tok.len;
        if (pos + need > buf.len) return null;
        if (!first) {
            buf[pos] = ' ';
            pos += 1;
        }
        @memcpy(buf[pos..][0..tok.len], tok);
        pos += tok.len;
        first = false;
    }
    return buf[0..pos];
}

const testing = std.testing;

test "sessionName formats pane sessions" {
    const u = "0f8fad5b-d9cb-469f-a165-70867728950e";
    var buf: [64]u8 = undefined;
    const got = sessionName(@ptrCast(u[0..36]), &buf).?;
    try testing.expectEqualStrings("seance-0f8fad5b-d9cb-469f-a165-70867728950e", got);
    // exact-size buffer works, smaller fails
    var tight: [43]u8 = undefined;
    _ = sessionName(@ptrCast(u[0..36]), &tight).?;
    var small: [42]u8 = undefined;
    try testing.expect(sessionName(@ptrCast(u[0..36]), &small) == null);
}

test "normalizeUuidList drops garbage and reflows spaces" {
    const good = "0f8fad5b-d9cb-469f-a165-70867728950e";
    const good2 = "1234abcd-12ab-469f-a165-70867728950f";
    var buf: [256]u8 = undefined;
    const got = normalizeUuidList(good ++ "  xx  " ++ good2 ++ " zzz", &buf).?;
    try testing.expectEqualStrings(good ++ " " ++ good2, got);
    // overflow-safe
    var tiny: [10]u8 = undefined;
    try testing.expect(normalizeUuidList(good, &tiny) == null);
    // all-garbage list → empty
    try testing.expectEqualStrings("", normalizeUuidList("nope nope", &buf).?);
}
