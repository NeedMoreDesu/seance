//! zmx integration primitives — pure, no GTK/ghostty, unit-testable.
//!
//! Session naming: each terminal (Pane) mints a UUID (uuid.zig) that is
//! persisted in session.json; its zmx session is "seance-<pane-uuid>".
//! Tabs additionally own a UUID used as the grouping id in session labels.
//!
//! Kill policy (when [behavior] zmx-attach = true):
//!   - explicit closes (pane, stacked tab, workspace, window) KEEP the
//!     session: it detaches and a revive snapshot lands in the close
//!     history (close_history.zig) for the undo keybind.
//!   - the zmx_* close keybinds (pane/tab) kill sessions instead; window
//!     close has no kill variant (cleanup = zmx_kill_unattached)
//!   - zmx_kill_unattached kills every clients=0 `seance-*` session not
//!     owned by a currently-open pane
//!   - WHOLE-APP quit → kill NOTHING (sessions survive for re-attach)

const std = @import("std");
const uuid = @import("uuid.zig");

pub const session_prefix = "seance-";

/// Kill-one-each command template. The pane-UUID list is passed out-of-band
/// via SEANCE_PANE_UUIDS (space-separated) so a 200-pane tab still fits in
/// the 1024-char command cap of the spawner and the envp size limit
/// protects the tail case.
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

/// zmx keeps one unix socket per session under `$XDG_RUNTIME_DIR/zmx/`.
pub const runtime_dir_name = "zmx";

/// Fast synchronous liveness hint: does the daemon socket for this pane's
/// session exist? (The authoritative answer — including client counts and
/// stale sockets — comes from parsing `zmx list` output.)
pub fn socketExists(runtime_dir: []const u8, pane_uuid: []const u8) bool {
    const io_mod = @import("io.zig");
    if (pane_uuid.len != uuid.len or !isValidUuidToken(pane_uuid)) return false;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        "{s}/{s}/{s}{s}",
        .{ runtime_dir, runtime_dir_name, session_prefix, pane_uuid },
    ) catch return false;
    std.Io.Dir.accessAbsolute(io_mod.get(), path, .{}) catch return false;
    return true;
}

pub const SessionRow = struct {
    pane_uuid: [uuid.len]u8,
    clients: u32,
};

/// Parse `zmx list` output: tab-separated kv lines such as
/// `  name=seance-<uuid>\tpid=1\tclients=0\t...`. Only rows whose name is
/// exactly `seance-<valid uuid>` are collected — the sweep must never
/// touch sessions seance did not spawn.
pub fn parseListSessions(alloc: std.mem.Allocator, output: []const u8) !std.ArrayList(SessionRow) {
    var rows: std.ArrayList(SessionRow) = .empty;
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var id: ?[uuid.len]u8 = null;
        var clients: u32 = 0;
        var fields = std.mem.splitScalar(u8, line, '\t');
        while (fields.next()) |field| {
            if (std.mem.startsWith(u8, field, "name=")) {
                const val = field["name=".len..];
                if (std.mem.startsWith(u8, val, session_prefix)) {
                    const rest = val[session_prefix.len..];
                    if (isValidUuidToken(rest)) {
                        var copy: [uuid.len]u8 = undefined;
                        @memcpy(&copy, rest[0..uuid.len]);
                        id = copy;
                    }
                }
            } else if (std.mem.startsWith(u8, field, "clients=")) {
                clients = std.fmt.parseInt(u32, field["clients=".len..], 10) catch 0;
            }
        }
        if (id) |u| try rows.append(alloc, .{ .pane_uuid = u, .clients = clients });
    }
    return rows;
}

/// Space-separated UUIDs of detached (clients=0) sessions from parsed
/// list rows, fitting into `buf` (truncated on overflow). `owned` holds
/// the UUIDs of terminals still OPEN in this app: their sessions can be
/// legitimately detached (restored workspaces only spawn their shell
/// when first shown) and must never be counted or swept.
pub fn detachedUuidList(rows: []const SessionRow, owned: []const [uuid.len]u8, buf: []u8) []const u8 {
    var pos: usize = 0;
    for (rows) |r| {
        if (r.clients != 0) continue;
        if (isOwned(&r.pane_uuid, owned)) continue;
        const need: usize = (if (pos == 0) @as(usize, 0) else 1) + uuid.len;
        if (pos + need > buf.len) break;
        if (pos > 0) {
            buf[pos] = ' ';
            pos += 1;
        }
        @memcpy(buf[pos..][0..uuid.len], &r.pane_uuid);
        pos += uuid.len;
    }
    return buf[0..pos];
}

/// Count of detached, not-otherwise-owned sessions (sidebar indicator).
pub fn detachedCount(rows: []const SessionRow, owned: []const [uuid.len]u8) usize {
    var n: usize = 0;
    for (rows) |r| {
        if (r.clients != 0) continue;
        if (isOwned(&r.pane_uuid, owned)) continue;
        n += 1;
    }
    return n;
}

fn isOwned(id: *const [uuid.len]u8, owned: []const [uuid.len]u8) bool {
    for (owned) |o| {
        if (std.mem.eql(u8, o[0..], id[0..])) return true;
    }
    return false;
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

test "parseListSessions: real-shape output, seance-only, client counts" {
    // Fixture mirrors `zmx list` (v0.8.1): indented tab-separated kv lines.
    const out = "  name=seance-20b9c01d-881f-4a2f-bb75-ac5a3d34ed43\tpid=85292\tclients=0\tcreated=1794347621\tcwd=/home/mika\tcmd=bash --posix\tpane=20b9c01d-881f-4a2f-bb75-ac5a3d34ed43\ttab=b115f8a9" ++
        "\n  name=scratch\tpid=99\tclients=2" ++
        "\n  name=seance-42cb94ae-100d-4d0e-9a3c-d36aad7545dd\tpid=178626\tclients=1\tcreated=1794362446\tcwd=/home\tcmd=bash\tpane=42cb94ae" ++
        "\n  name=seance-not-a-uuid\tpid=1\tclients=0" ++
        "\ngarbage line without fields\n";
    const alloc = testing.allocator;
    var rows = try parseListSessions(alloc, out);
    defer rows.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), rows.items.len);
    try testing.expectEqual(@as(u32, 0), rows.items[0].clients);
    try testing.expectEqual(@as(u32, 1), rows.items[1].clients);

    var owned: [1][uuid.len]u8 = undefined;
    @memcpy(&owned[0], "20b9c01d-881f-4a2f-bb75-ac5a3d34ed43");
    var buf: [256]u8 = undefined;
    // The first row's uuid is OWNED (live pane whose shell has not spawned
    // yet): excluded from both the kill list and the count.
    try testing.expectEqualStrings(
        "",
        detachedUuidList(rows.items, owned[0..], &buf),
    );
    try testing.expectEqual(@as(usize, 0), detachedCount(rows.items, owned[0..]));
    const none: [0][uuid.len]u8 = .{};
    try testing.expectEqualStrings(
        "20b9c01d-881f-4a2f-bb75-ac5a3d34ed43",
        detachedUuidList(rows.items, none[0..], &buf),
    );
    try testing.expectEqual(@as(usize, 1), detachedCount(rows.items, none[0..]));
    // empty list → empty string
    try testing.expectEqualStrings("", detachedUuidList(&.{}, none[0..], &buf));
    try testing.expectEqual(@as(usize, 0), detachedCount(&.{}, none[0..]));
}

test "socketExists: uuid shape validation without touching the fs" {
    // Garbage tokens are rejected before any path is built.
    try testing.expect(!socketExists("/nonexistent-xyz", "nope"));
    try testing.expect(!socketExists("/nonexistent-xyz", "0f8fad5b-d9cb-469f-a165-70867728950Z"));
    // A valid uuid against a nonexistent runtime dir is simply not there.
    try testing.expect(!socketExists("/nonexistent-xyz", "0f8fad5b-d9cb-469f-a165-70867728950e"));
}
