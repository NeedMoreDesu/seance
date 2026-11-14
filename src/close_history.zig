//! Close history — a LIFO memory of explicitly closed terminals, tabs and
//! windows, stored SEPARATELY from session.json (~/.config/seance/
//! close_history.json).
//!
//! With [behavior] zmx-attach = true, closing a pane/tab/window keeps its
//! zmx sessions alive (the daemons outlive the pane shells; the normal quit
//! path kills nothing). The snapshot needed to REVIVE what was
//! closed lands in the history, so the "Undo Tab Close (zmx)" keybind can
//! recreate it and its shells re-attach to the surviving sessions —
//! browser-style, in reverse close order.
//!
//! Rules:
//!   - An item is recorded only when it can revive zmx: at least one of
//!     its terminal sessions is still alive (socket present).
//!   - Entries whose sessions have all died are dropped on every zmx scan
//!     (which also runs at startup).
//!   - session.json keeps holding ONLY live windows; a closed window is
//!     pruned there as upstream does. It is revivable from here instead.
//!   - The list is bounded (MAX_ENTRIES); evicted oldest entries vanish
//!     silently. Their detached sessions linger until the kill-unattached
//!     keybind (zmx_kill_unattached) sweeps them up.

const std = @import("std");
const io = @import("io.zig");
const c = @import("c.zig").c;
const config_mod = @import("config.zig");
const uuid = @import("uuid.zig");
const zmx = @import("zmx.zig");
const Workspace = @import("workspace.zig").Workspace;
const WindowState = @import("window.zig").WindowState;
const PaneGroup = @import("pane_group.zig").PaneGroup;
const Column = @import("column.zig").Column;

const Allocator = std.mem.Allocator;

pub const MAX_ENTRIES: usize = 32;
const SCAN_INTERVAL_SECS: u32 = 5;

/// After a sweep is issued, `zmx kill` runs asynchronously. Rescan on a
/// short timer (retrying a few times) so the sidebar settles as soon as
/// the daemons are gone instead of waiting for the next periodic tick.
const RECONCILE_DELAY_MS: u32 = 150;
const RECONCILE_TRIES: u8 = 10;

pub const Kind = enum { pane, tab, window };

fn kindName(k: Kind) []const u8 {
    return switch (k) {
        .pane => "pane",
        .tab => "tab",
        .window => "window",
    };
}

fn kindFromName(s: []const u8) ?Kind {
    if (std.mem.eql(u8, s, "pane")) return .pane;
    if (std.mem.eql(u8, s, "tab")) return .tab;
    if (std.mem.eql(u8, s, "window")) return .window;
    return null;
}

pub const Entry = struct {
    kind: Kind,
    closed_at: i64,
    /// Runtime id of the window the item belonged to (0 = unknown). Best-
    /// effort anchor; revival falls back to tab_uuid match / active window.
    window_id: u64,
    /// Anchor workspace for pane/tab entries (null for windows).
    tab_uuid: ?[uuid.len]u8,
    /// tab: workspace index at close. pane: column index at close.
    index: usize,
    /// pane: width (fraction) of the doomed column, 0 = unknown.
    col_width: f64,
    col_tabbed: bool,
    /// Owned, space-separated pane UUIDs of the terminals in this item.
    sessions: []u8,
    /// Owned revive snapshot: full window object (window), full workspace
    /// object (tab), or {"col_width":..,"col_layout_mode":..,"panels":[..]}.
    json: []u8,
};

var gpa = std.heap.DebugAllocator(.{}){};
var entries: std.ArrayList(Entry) = .empty;
var loaded = false;

/// Latest `zmx list` detached-session count (clients=0, seance- prefix).
var detached_count: usize = 0;
/// Subset of `detached_count` whose daemon is unreachable (stale socket).
var unreachable_count: usize = 0;

/// Latest successful scan rows. Kept so record()/undoLast() can reject
/// sessions the daemon reports as unreachable without another round-trip.
var scan_rows: std.ArrayList(zmx.SessionRow) = .empty;
var have_scan = false;

var scan_in_flight = false;
var sweep_pending = false;
var sweep_optimistic = false;
var scan_timer: c.guint = 0;
var reconcile_timer: c.guint = 0;
var reconcile_tries: u8 = 0;

fn allocator() Allocator {
    return gpa.allocator();
}

pub fn getPath(buf: []u8) ?[]const u8 {
    const home = io.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/seance/close_history.json", .{home}) catch null;
}

pub fn entryCount() usize {
    load();
    return entries.items.len;
}

pub fn unattachedCount() usize {
    return detached_count;
}

// ── Record / pop / prune ────────────────────────────────────────────────

pub const RecordArgs = struct {
    kind: Kind,
    window_id: u64 = 0,
    tab_uuid: ?[uuid.len]u8 = null,
    index: usize = 0,
    col_width: f64 = 0,
    col_tabbed: bool = false,
    sessions: []const u8 = "",
    json: []const u8 = "",
};

/// Append a closed item's revive snapshot. Silently skipped when zmx
/// cannot revive it (no live sessions), the snapshot is empty, or the
/// UUID list is corrupt.
pub fn record(args: RecordArgs) void {
    load();
    if (args.json.len == 0) return;

    var norm_buf: [16384]u8 = undefined;
    const normed = zmx.normalizeUuidList(args.sessions, &norm_buf) orelse return;
    if (normed.len == 0) return;

    // Only save if we can revive zmx: at least one of the item's terminal
    // sessions must still be alive. (Sockets are per-session files under
    // $XDG_RUNTIME_DIR/zmx — cheap synchronous check; the periodic scan
    // remains the authority for pruning.)
    const runtime_dir = config_mod.runtimeDir();
    var toks = std.mem.tokenizeScalar(u8, normed, ' ');
    var any_alive = false;
    while (toks.next()) |u| {
        if (knownUnreachable(u)) continue;
        if (zmx.socketExists(runtime_dir, u)) {
            any_alive = true;
            break;
        }
    }
    if (!any_alive) return;

    const a = allocator();
    const sessions = a.dupe(u8, normed) catch return;
    const snapshot = a.dupe(u8, args.json) catch {
        a.free(sessions);
        return;
    };
    entries.append(a, .{
        .kind = args.kind,
        .closed_at = io.timestamp(),
        .window_id = args.window_id,
        .tab_uuid = args.tab_uuid,
        .index = args.index,
        .col_width = args.col_width,
        .col_tabbed = args.col_tabbed,
        .sessions = sessions,
        .json = snapshot,
    }) catch {
        a.free(sessions);
        a.free(snapshot);
        return;
    };

    // Bounded memory: evict the oldest closes. Their sessions may still
    // exist detached — the kill-unattached sweep is the cleanup tool.
    while (entries.items.len > MAX_ENTRIES) {
        freeEntry(entries.orderedRemove(0));
    }

    save();
}

fn freeEntry(e: Entry) void {
    const a = allocator();
    a.free(e.sessions);
    a.free(e.json);
}

/// Undo the most recent close: pop the newest entry that actually
/// revives (entries whose sessions died in the meantime are dropped).
pub fn undoLast() bool {
    load();
    var popped = false;
    var revived = false;
    while (entries.items.len > 0) {
        const e = entries.orderedRemove(entries.items.len - 1);
        popped = true;
        if (allKnownUnreachable(e)) {
            std.log.warn("close_history: dropping unreachable entry (kind={s})", .{kindName(e.kind)});
            freeEntry(e);
            continue;
        }
        if (revive(&e)) {
            freeEntry(e);
            revived = true;
            break;
        }
        std.log.warn("close_history: revive failed (kind={s})", .{kindName(e.kind)});
        freeEntry(e);
    }
    if (popped) save();
    if (revived) triggerScan();
    return revived;
}

/// Drop every entry that has NO live session among the parsed rows
/// (rows include detached daemons — presence = alive). Returns true when
/// something was removed; the caller decides when to persist.
fn prune(rows: []const zmx.SessionRow) bool {
    var changed = false;
    var i: usize = 0;
    while (i < entries.items.len) {
        if (entryRevivable(entries.items[i], rows)) {
            i += 1;
            continue;
        }
        freeEntry(entries.orderedRemove(i));
        changed = true;
    }
    return changed;
}

fn entryRevivable(e: Entry, rows: []const zmx.SessionRow) bool {
    var toks = std.mem.tokenizeScalar(u8, e.sessions, ' ');
    while (toks.next()) |u| {
        for (rows) |r| {
            if (r.reachable and std.mem.eql(u8, &r.pane_uuid, u)) return true;
        }
    }
    return false;
}

/// True when the last scan explicitly reported this session unreachable.
/// Sessions merely absent from the list are dead (pruned by `prune`), but
/// a fresh close may predate the next scan — so only an explicit
/// unreachable verdict blocks record/undo.
fn knownUnreachable(u: []const u8) bool {
    if (!have_scan) return false;
    for (scan_rows.items) |r| {
        if (!r.reachable and std.mem.eql(u8, &r.pane_uuid, u)) return true;
    }
    return false;
}

/// True when every session of the entry is known unreachable (no shell can
/// re-attach). Such an entry is dropped by undo without attempting a revive.
fn allKnownUnreachable(e: Entry) bool {
    if (!have_scan) return false;
    var toks = std.mem.tokenizeScalar(u8, e.sessions, ' ');
    var any = false;
    while (toks.next()) |u| {
        any = true;
        if (!knownUnreachable(u)) return false;
    }
    return any;
}

fn replaceScanRows(rows: []const zmx.SessionRow) void {
    const a = allocator();
    scan_rows.clearRetainingCapacity();
    scan_rows.appendSlice(a, rows) catch {};
    have_scan = true;
}

// ── Persistence ─────────────────────────────────────────────────────────

fn load() void {
    if (loaded) return;
    loaded = true;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = getPath(&path_buf) orelse return;
    const a = allocator();

    const data = std.Io.Dir.cwd().readFileAlloc(io.get(), path, a, .limited(64 * 1024 * 1024)) catch return;
    defer a.free(data);

    const parsed = std.json.parseFromSlice(std.json.Value, a, data, .{}) catch {
        std.log.warn("close_history: corrupt file, starting fresh", .{});
        return;
    };
    defer parsed.deinit();

    if (parsed.value != .array) return;
    for (parsed.value.array.items) |item| {
        const e = entryFromJson(item) orelse continue;
        entries.append(a, e) catch {
            freeEntry(e);
            return;
        };
    }
    while (entries.items.len > MAX_ENTRIES) {
        freeEntry(entries.orderedRemove(0));
    }
}

fn entryFromJson(item: std.json.Value) ?Entry {
    if (item != .object) return null;
    const o = item.object;
    const a = allocator();

    const kind = kindFromName(jsonStr(o, "kind") orelse "") orelse return null;

    const snap = o.get("json") orelse return null;
    switch (snap) {
        .object, .array => {},
        else => return null,
    }
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    out.writer.print("{f}", .{std.json.fmt(snap, .{})}) catch return null;
    const snapshot = out.toOwnedSlice() catch return null;

    const sessions_src = jsonStr(o, "sessions") orelse "";
    var norm_buf: [16384]u8 = undefined;
    const normed = zmx.normalizeUuidList(sessions_src, &norm_buf) orelse "";
    if (normed.len == 0) {
        a.free(snapshot);
        return null;
    }
    const sessions = a.dupe(u8, normed) catch {
        a.free(snapshot);
        return null;
    };

    const tab: ?[uuid.len]u8 = blk: {
        const t = jsonStr(o, "tab_uuid") orelse break :blk null;
        if (t.len != uuid.len) break :blk null;
        var copy: [uuid.len]u8 = undefined;
        @memcpy(&copy, t[0..uuid.len]);
        break :blk copy;
    };

    const wid_raw = jsonInt(o, "window_id") orelse 0;
    const idx_raw = jsonInt(o, "index") orelse 0;
    return .{
        .kind = kind,
        .closed_at = jsonInt(o, "closed_at") orelse 0,
        .window_id = if (wid_raw > 0) @intCast(wid_raw) else 0,
        .tab_uuid = tab,
        .index = if (idx_raw > 0) @intCast(idx_raw) else 0,
        .col_width = jsonFloat(o, "col_width") orelse 0,
        .col_tabbed = std.mem.eql(u8, jsonStr(o, "col_layout_mode") orelse "", "tabbed"),
        .sessions = sessions,
        .json = snapshot,
    };
}

fn save() void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = getPath(&path_buf) orelse return;

    const a = allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const w = &out.writer;

    w.writeByte('[') catch return;
    for (entries.items, 0..) |e, i| {
        if (i > 0) w.writeByte(',') catch return;
        writeEntry(w, e) catch return;
    }
    w.writeByte(']') catch return;

    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io.get(), dir) catch {};
    }
    const file = std.Io.Dir.cwd().createFile(io.get(), path, .{}) catch |err| {
        std.log.warn("close_history: create failed: {s}", .{@errorName(err)});
        return;
    };
    defer file.close(io.get());
    file.writeStreamingAll(io.get(), out.written()) catch |err| {
        std.log.warn("close_history: write failed: {s}", .{@errorName(err)});
    };
}

fn writeEntry(w: anytype, e: Entry) !void {
    try w.print(
        "{{\"kind\":\"{s}\",\"closed_at\":{d},\"window_id\":{d},\"index\":{d},\"col_width\":{d:.4}",
        .{ kindName(e.kind), e.closed_at, e.window_id, e.index, e.col_width },
    );
    try w.print(",\"col_layout_mode\":\"{s}\"", .{if (e.col_tabbed) "tabbed" else "stacked"});
    if (e.tab_uuid) |*id| {
        try w.print(",\"tab_uuid\":\"{s}\"", .{id});
    }
    try w.print(",\"sessions\":\"{s}\",\"json\":{s}}}", .{ e.sessions, e.json });
}

fn jsonStr(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = o.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(o: std.json.ObjectMap, key: []const u8) ?i64 {
    const val = o.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

fn jsonFloat(o: std.json.ObjectMap, key: []const u8) ?f64 {
    const val = o.get(key) orelse return null;
    return switch (val) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

// ── Revive ──────────────────────────────────────────────────────────────

fn revive(e: *const Entry) bool {
    const session_mod = @import("session.zig");
    const Window = @import("window.zig");
    const wm = Window.window_manager orelse return false;

    const a = allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, a, e.json, .{}) catch return false;
    defer parsed.deinit();

    return switch (e.kind) {
        .window => session_mod.reviveWindowJson(wm, parsed.value, true),
        .tab => reviveTab(wm, e, parsed.value),
        .pane => revivePane(wm, e, parsed.value),
    };
}

fn reviveTab(wm: anytype, e: *const Entry, ws_val: std.json.Value) bool {
    const session_mod = @import("session.zig");
    const target = findWindow(wm, e.window_id) orelse wm.active_window;
    if (target) |st| {
        if (session_mod.reviveWorkspaceInto(st, ws_val, e.index)) {
            finishWorkspace(st, e.index);
            return true;
        }
        // Fall through to the synthetic-window path only when there is
        // no live window to host the tab; a failed restore is final.
        if (wm.windows.items.len > 0) return false;
    }
    // No live window: wrap the workspace snapshot in a minimal window
    // object and revive that (one undo → one restored window).
    var out: std.Io.Writer.Allocating = .init(allocator());
    defer out.deinit();
    const w = &out.writer;
    w.writeAll("{\"sidebar_visible\":true,\"width\":1200,\"height\":800,\"workspaces\":[") catch return false;
    w.writeAll(e.json) catch return false;
    w.writeAll("]}") catch return false;

    const a = allocator();
    const parsed = std.json.parseFromSlice(std.json.Value, a, out.written(), .{}) catch return false;
    defer parsed.deinit();
    return session_mod.reviveWindowJson(wm, parsed.value, true);
}

fn finishWorkspace(state: *WindowState, index: usize) void {
    if (state.workspaces.items.len == 0) return;
    state.selectWorkspace(@min(index, state.workspaces.items.len - 1));
    state.sidebar.refresh();
    sessionSaveAll(state.window_manager);
}

fn sessionSaveAll(wm: anytype) void {
    @import("session.zig").saveAll(wm, false);
}

fn findWindow(wm: anytype, id: u64) ?*WindowState {
    if (id == 0) return null;
    for (wm.windows.items) |st| {
        if (st.destroyed) continue;
        if (st.id == id) return st;
    }
    return null;
}

const Found = struct {
    state: *WindowState,
    ws: *Workspace,
    idx: usize,
};

fn findWorkspaceByTab(wm: anytype, want_window_id: u64, tab: ?[uuid.len]u8) ?Found {
    const tab_id = tab orelse return null;
    for (wm.windows.items) |st| {
        if (st.destroyed) continue;
        if (want_window_id != 0 and st.id != want_window_id) continue;
        for (st.workspaces.items, 0..) |ws, i| {
            if (std.mem.eql(u8, &ws.tab_uuid, &tab_id)) {
                return .{ .state = st, .ws = ws, .idx = i };
            }
        }
    }
    return null;
}

fn revivePane(wm: anytype, e: *const Entry, val: std.json.Value) bool {
    const session_mod = @import("session.zig");

    // Anchor: the workspace this pane lived in, by tab_uuid (original
    // window first, then any window). Fallback: the active window's
    // active workspace — the undo lands as a split "here".
    const found = findWorkspaceByTab(wm, e.window_id, e.tab_uuid) orelse
        findWorkspaceByTab(wm, 0, e.tab_uuid);

    var state_opt: ?*WindowState = null;
    if (found) |f| state_opt = f.state;
    if (state_opt == null) state_opt = wm.active_window;
    if (state_opt == null or state_opt.?.destroyed) {
        state_opt = wm.newWindow();
    }
    const state = state_opt orelse {
        std.log.warn("close_history: revivePane: no window available", .{});
        return false;
    };
    if (state.destroyed) return false;

    const ws: *Workspace = if (found) |f| f.ws else (state.activeWorkspace() orelse return false);
    const target_ws_idx: usize = if (found) |f| f.idx else state.active_workspace;

    const obj = switch (val) {
        .object => |o| o,
        else => {
            std.log.warn("close_history: revivePane: snapshot not an object", .{});
            return false;
        },
    };
    const panels_val = obj.get("panels") orelse {
        std.log.warn("close_history: revivePane: snapshot has no panels array", .{});
        return false;
    };
    if (panels_val != .array) return false;
    const panels = panels_val.array.items;
    if (panels.len == 0) return false;

    const col_width = jsonFloat(obj, "col_width") orelse 0;
    const col_tabbed = std.mem.eql(u8, jsonStr(obj, "col_layout_mode") orelse "", "tabbed");

    // Recorded column index → the e.index-th live column.
    var col: ?*Column = null;
    var col_idx: usize = 0;
    var live: usize = 0;
    for (ws.columns.items, 0..) |*candidate, ci| {
        if (candidate.closing) continue;
        if (live == e.index) {
            col = candidate;
            col_idx = ci;
            break;
        }
        live += 1;
    }

    var grp: *PaneGroup = undefined;
    var new_col = false;
    if (col) |existing| {
        if (existing.groups.items.len == 0) return false;
        grp = existing.groups.items[0];
    } else {
        // The whole column went away with the pane — re-split.
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_z: ?[*:0]const u8 = firstPanelCwd(&cwd_buf, panels[0]);
        grp = ws.addColumn(cwd_z) catch {
            std.log.warn("close_history: revivePane: addColumn failed", .{});
            return false;
        };
        new_col = true;
        col_idx = liveColumnIndexOf(ws, grp);
    }

    var revived: usize = 0;
    for (panels, 0..) |pv, pi| {
        if (session_mod.reviveTerminalPanel(grp, pv, new_col and pi == 0) != null) {
            revived += 1;
        }
    }
    if (revived == 0) {
        std.log.warn("close_history: revivePane: no panel revived from snapshot", .{});
        return false;
    }

    if (new_col) {
        for (ws.columns.items) |*candidate| {
            var is_ours = false;
            for (candidate.groups.items) |g| {
                if (g == grp) is_ours = true;
            }
            if (!is_ours) continue;
            if (col_width > 0) {
                const clamped = std.math.clamp(col_width, Column.min_width, Column.max_width);
                candidate.width = clamped;
                candidate.target_width = clamped;
            }
            if (col_tabbed) {
                candidate.layout_mode = .tabbed;
                candidate.stacked_anim = 0.0;
                grp.exitStackedMode();
            }
            break;
        }
    }

    ws.focused_column = @min(col_idx, ws.columns.items.len - 1);
    ws.applyLayout();
    grp.switchToPanel(grp.panels.items.len - 1);
    grp.focus();

    if (target_ws_idx != state.active_workspace and target_ws_idx < state.workspaces.items.len) {
        state.selectWorkspace(target_ws_idx);
    }
    state.sidebar.refresh();
    sessionSaveAll(wm);
    return true;
}

fn liveColumnIndexOf(ws: *Workspace, grp: *PaneGroup) usize {
    for (ws.columns.items, 0..) |*col, ci| {
        if (col.closing) continue;
        for (col.groups.items) |g| {
            if (g == grp) return ci;
        }
    }
    if (ws.columns.items.len == 0) return 0;
    return ws.columns.items.len - 1;
}

fn firstPanelCwd(buf: *[std.fs.max_path_bytes]u8, panel_val: std.json.Value) ?[*:0]const u8 {
    const obj = switch (panel_val) {
        .object => |o| o,
        else => return null,
    };
    const cwd = jsonStr(obj, "cwd") orelse return null;
    if (cwd.len == 0 or cwd.len >= buf.len) return null;
    @memcpy(buf[0..cwd.len], cwd);
    buf[cwd.len] = 0;
    return @ptrCast(buf);
}

// ── zmx list scan: detached count, history prune, sweep ─────────────────

/// Load the file and start the periodic scan. Safe to call once per app
/// launch (idempotent).
pub fn start() void {
    load();
    if (scan_timer != 0) return;
    scan_timer = c.g_timeout_add_seconds(SCAN_INTERVAL_SECS, @ptrCast(&onTimer), null);
    requestScan(false);
}

fn onTimer(_: c.gpointer) callconv(.c) c.gboolean {
    if (!config_mod.get().zmx_attach) {
        // Feature off: hide the sidebar indicator and stop scanning.
        if (detached_count != 0 or unreachable_count != 0) {
            detached_count = 0;
            unreachable_count = 0;
            updateSidebars();
        }
        sweep_optimistic = false;
        reconcile_tries = 0;
        return 1;
    }
    requestScan(false);
    return 1;
}

/// Kick a `zmx list` scan (worker thread; results land on the main
/// thread). At most one scan runs at a time; a sweep requested while one
/// is in flight is dispatched as soon as that pass finishes.
pub fn triggerScan() void {
    requestScan(false);
}

/// Kill every detached (`clients=0`) `seance-*` session, except those
/// belonging to panes that are open right now (their shells may simply
/// not have been spawned yet — restored workspaces attach lazily).
/// Sessions not spawned by seance (any other name) are never touched.
pub fn killUnattached() void {
    if (!config_mod.get().zmx_attach) return;
    // The user just asked to destroy every detached session, so dismiss
    // the indicator immediately instead of leaving it up through the
    // `zmx list` round-trip and the async kills. The post-sweep reconcile
    // scan restores the real count if anything refused to die.
    if (detached_count != 0 or unreachable_count != 0) {
        detached_count = 0;
        unreachable_count = 0;
        updateSidebars();
    }
    sweep_optimistic = true;
    requestScan(true);
}

/// Synchronously snapshot every `seance-*` session UUID (attached or
/// detached) from `zmx list`, space-separated into `buf`. Used by the
/// quit-and-kill-all shortcut, which cannot wait for the async scan.
fn allSessionUuids(buf: []u8) []const u8 {
    const a = allocator();
    const res = std.process.run(a, io.get(), .{
        .argv = &[_][]const u8{ "zmx", "list" },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return buf[0..0];
    defer a.free(res.stdout);
    defer a.free(res.stderr);
    const exited_ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exited_ok) return buf[0..0];

    var rows = zmx.parseListSessions(a, res.stdout) catch return buf[0..0];
    defer rows.deinit(a);
    return zmx.allUuidList(rows.items, buf);
}

/// Destroy every zmx session seance owns, attached or detached. Reached
/// only from the quit-and-kill-all path (after the session snapshot is
/// saved); the detached kill shell finishes after the app exits.
pub fn killAllSessions() void {
    if (!config_mod.get().zmx_attach) return;
    var buf: [16384]u8 = undefined;
    const uuids = allSessionUuids(&buf);
    if (uuids.len > 0) WindowState.killZmxSessions(uuids);
}

const ScanWork = struct {
    sweep: bool,
    ok: bool = false,
    output: []u8 = "",
};

fn requestScan(sweep: bool) void {
    // Feature off: don't spawn zmx, don't prune (history stays intact in
    // case the user toggles zmx back on).
    if (!config_mod.get().zmx_attach) return;
    if (sweep) sweep_pending = true;
    if (scan_in_flight) return;
    const want_sweep = sweep_pending;
    sweep_pending = false;

    const a = allocator();
    const work = a.create(ScanWork) catch return;
    work.* = .{ .sweep = want_sweep };

    scan_in_flight = true;
    const thread = std.Thread.spawn(.{}, scanWorker, .{work}) catch {
        scan_in_flight = false;
        a.destroy(work);
        sweep_pending = want_sweep; // retry next tick
        return;
    };
    thread.detach();
}

fn scanWorker(work: *ScanWork) void {
    const a = allocator();
    if (std.process.run(a, io.get(), .{
        .argv = &[_][]const u8{ "zmx", "list" },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    })) |res| {
        a.free(res.stderr);
        const exited_ok = switch (res.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (exited_ok) {
            work.ok = true;
            work.output = res.stdout;
        } else {
            a.free(res.stdout);
        }
    } else |_| {}
    _ = c.g_idle_add(@ptrCast(&onScanIdle), @ptrCast(work));
}

fn onScanIdle(data: c.gpointer) callconv(.c) c.gboolean {
    scan_in_flight = false;
    const work: *ScanWork = @ptrCast(@alignCast(data));
    const a = allocator();
    defer a.destroy(work);

    if (!work.ok) {
        // zmx unreachable: don't prune on guesswork; the next tick retries.
        return 0;
    }

    var rows = zmx.parseListSessions(a, work.output) catch {
        a.free(work.output);
        return 0;
    };
    defer rows.deinit(a);
    a.free(work.output);

    // Presence in the list = daemon alive (attached or detached).
    // Everything else in the history is dead memory — drop it. Rows
    // flagged unreachable keep their stale socket but cannot revive.
    replaceScanRows(rows.items);
    if (prune(rows.items)) save();

    // Sessions of panes that are OPEN right now must never count or die:
    // restored workspaces only spawn a shell when first shown, so their
    // sessions sit at clients=0 legitimately. The sweep targets detached
    // orphans only.
    var owned = livePaneUuids(a);
    defer owned.deinit(a);

    var det_buf: [16384]u8 = undefined;
    const detached = zmx.detachedUuidList(rows.items, owned.items, &det_buf);

    const count = zmx.detachedCount(rows.items, owned.items);
    const unreachable_n = zmx.unreachableDetachedCount(rows.items, owned.items);
    const sweeping = work.sweep or sweep_pending;

    // While kills settle, keep the optimistic zero from killUnattached()
    // instead of repainting a scan that raced them. Only show the real
    // count once it is zero or the retries are exhausted.
    if (sweep_optimistic or sweeping) {
        if (count == 0) {
            sweep_optimistic = false;
            reconcile_tries = 0;
            detached_count = 0;
            unreachable_count = 0;
            updateSidebars();
        } else if (work.sweep) {
            if (detached.len > 0) WindowState.killZmxSessions(detached);
            scheduleReconcile(RECONCILE_TRIES);
        } else if (sweep_pending) {
            // The queued sweep (dispatched below) owns the result.
        } else if (reconcile_tries > 0) {
            reconcile_tries -= 1;
            if (reconcile_tries > 0) {
                scheduleReconcile(reconcile_tries);
            } else {
                sweep_optimistic = false;
                detached_count = count;
                unreachable_count = unreachable_n;
                updateSidebars();
            }
        } else {
            sweep_optimistic = false;
            detached_count = count;
            unreachable_count = unreachable_n;
            updateSidebars();
        }
    } else {
        detached_count = count;
        unreachable_count = unreachable_n;
        updateSidebars();
    }

    // A sweep requested while this scan was in flight must not wait for the
    // next periodic tick.
    if (sweep_pending) requestScan(false);
    return 0;
}

/// Queue a scan for shortly after the async sweeps. `tries` bounds how
/// many times a still-nonzero count reschedules itself.
fn scheduleReconcile(tries: u8) void {
    if (tries == 0) return;
    if (tries > reconcile_tries) reconcile_tries = tries;
    if (reconcile_timer != 0) return;
    reconcile_timer = c.g_timeout_add(RECONCILE_DELAY_MS, @ptrCast(&onReconcile), null);
}

fn onReconcile(_: c.gpointer) callconv(.c) c.gboolean {
    reconcile_timer = 0;
    if (reconcile_tries == 0) return 0;
    if (scan_in_flight) {
        // A periodic scan owns the slot; retry shortly (bounded).
        reconcile_tries -= 1;
        scheduleReconcile(reconcile_tries);
        return 0;
    }
    requestScan(false);
    return 0;
}

/// UUIDs of every terminal pane currently alive in the window tree.
fn livePaneUuids(a: Allocator) std.ArrayList([uuid.len]u8) {
    var list: std.ArrayList([uuid.len]u8) = .empty;
    const Window = @import("window.zig");
    const wm = Window.window_manager orelse return list;
    for (wm.windows.items) |st| {
        if (st.destroyed) continue;
        for (st.workspaces.items) |ws| {
            for (ws.columns.items) |col| {
                if (col.closing) continue;
                for (col.groups.items) |grp| {
                    for (grp.panels.items) |panel| {
                        const tp = panel.asTerminal() orelse continue;
                        if (tp.pane_uuid[0] == 0) continue;
                        list.append(a, tp.pane_uuid) catch return list;
                    }
                }
            }
        }
    }
    return list;
}

fn updateSidebars() void {
    const Window = @import("window.zig");
    const wm = Window.window_manager orelse return;
    const enabled = config_mod.get().zmx_attach;
    const n = if (enabled) detached_count else 0;
    const unreachable_n = if (enabled) @min(unreachable_count, n) else 0;
    for (wm.windows.items) |st| {
        if (st.destroyed) continue;
        st.sidebar.setZmxUnattached(n, unreachable_n);
    }
}

// ── Tests (serialization core, no GTK) ─────────────────────────────────

const testing = std.testing;

test "entryFromJson + writeEntry round-trip" {
    const src =
        \\{"kind":"pane","closed_at":111,"window_id":3,"index":1,"col_width":0.5,"col_layout_mode":"tabbed","tab_uuid":"0f8fad5b-d9cb-469f-a165-70867728950e","sessions":"1234abcd-12ab-469f-a165-70867728950f garbage 1234abcd-12ab-469f-a165-70867728950f","json":{"panels":[]}}
    ;

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, src, .{});
    defer parsed.deinit();

    const a = gpa.allocator();
    const e = entryFromJson(parsed.value) orelse return error.TestUnexpectedResult;
    // entryFromJson allocates from the module allocator; hand it back.
    defer {
        a.free(e.sessions);
        a.free(e.json);
    }

    try testing.expectEqual(Kind.pane, e.kind);
    try testing.expectEqual(@as(u64, 3), e.window_id);
    try testing.expectEqual(@as(usize, 1), e.index);
    try testing.expect(e.col_tabbed);
    // Corrupt token dropped; normalize does not dedupe, both valid
    // tokens survive (kill/sweep tolerate the repeat; the liveness probe
    // just sees the same id twice).
    try testing.expectEqualStrings(
        "1234abcd-12ab-469f-a165-70867728950f 1234abcd-12ab-469f-a165-70867728950f",
        e.sessions,
    );
    try testing.expect(e.tab_uuid != null);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeEntry(&out.writer, e);

    const re = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer re.deinit();
    const obj = switch (re.value) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("pane", obj.get("kind").?.string);
    try testing.expectEqual(@as(i64, 111), obj.get("closed_at").?.integer);
    // The snapshot re-embeds as a real JSON object, not a string.
    const snap = obj.get("json") orelse return error.TestUnexpectedResult;
    try testing.expect(snap == .object);
}

test "prune keeps entries with any live session, drops dead ones" {
    loaded = true; // don't touch the real file from a unit test
    defer loaded = false;
    const a = gpa.allocator();
    entries.clearRetainingCapacity();

    entries.append(a, .{
        .kind = .pane,
        .closed_at = 0,
        .window_id = 0,
        .tab_uuid = null,
        .index = 0,
        .col_width = 0,
        .col_tabbed = false,
        .sessions = try a.dupe(u8, "0f8fad5b-d9cb-469f-a165-70867728950e"),
        .json = try a.dupe(u8, "{}"),
    }) catch return error.TestUnexpectedResult;
    entries.append(a, .{
        .kind = .tab,
        .closed_at = 0,
        .window_id = 0,
        .tab_uuid = null,
        .index = 0,
        .col_width = 0,
        .col_tabbed = false,
        .sessions = try a.dupe(u8, "11111111-2222-4333-8444-555555555555"),
        .json = try a.dupe(u8, "{}"),
    }) catch return error.TestUnexpectedResult;

    var dead: [uuid.len]u8 = undefined;
    @memcpy(&dead, "0f8fad5b-d9cb-469f-a165-70867728950e");
    var rows = std.ArrayList(zmx.SessionRow).empty;
    defer rows.deinit(a);
    try rows.append(a, .{ .pane_uuid = dead, .clients = 0 });

    try testing.expect(prune(rows.items));
    try testing.expectEqual(@as(usize, 1), entries.items.len);
    // The survivor is the pane entry (its uuid was listed).
    try testing.expectEqual(Kind.pane, entries.items[0].kind);

    // zmx disappears entirely (empty list) → the survivor dies too.
    const no_rows: []const zmx.SessionRow = &.{};
    try testing.expect(prune(no_rows));
    try testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "prune drops entries whose only session is unreachable" {
    loaded = true; // don't touch the real file from a unit test
    defer loaded = false;
    const a = gpa.allocator();
    entries.clearRetainingCapacity();

    entries.append(a, .{
        .kind = .pane,
        .closed_at = 0,
        .window_id = 0,
        .tab_uuid = null,
        .index = 0,
        .col_width = 0,
        .col_tabbed = false,
        .sessions = try a.dupe(u8, "0f8fad5b-d9cb-469f-a165-70867728950e"),
        .json = try a.dupe(u8, "{}"),
    }) catch return error.TestUnexpectedResult;

    var stale: [uuid.len]u8 = undefined;
    @memcpy(&stale, "0f8fad5b-d9cb-469f-a165-70867728950e");
    var rows = std.ArrayList(zmx.SessionRow).empty;
    defer rows.deinit(a);
    // The stale socket still shows up in `zmx list`, but the daemon is
    // unreachable: it cannot revive, so the history entry must go.
    try rows.append(a, .{ .pane_uuid = stale, .clients = 0, .reachable = false });

    try testing.expect(prune(rows.items));
    try testing.expectEqual(@as(usize, 0), entries.items.len);
}

test "allKnownUnreachable: only explicit unreachable verdicts block undo" {
    loaded = true;
    defer loaded = false;
    have_scan = true;
    defer {
        have_scan = false;
        scan_rows.clearRetainingCapacity();
    }
    const a = gpa.allocator();
    scan_rows.clearRetainingCapacity();

    var alive: [uuid.len]u8 = undefined;
    @memcpy(&alive, "0f8fad5b-d9cb-469f-a165-70867728950e");
    var stale: [uuid.len]u8 = undefined;
    @memcpy(&stale, "1234abcd-12ab-469f-a165-70867728950f");
    try scan_rows.append(a, .{ .pane_uuid = alive, .clients = 1, .reachable = true });
    try scan_rows.append(a, .{ .pane_uuid = stale, .clients = 0, .reachable = false });

    const stale_entry: Entry = .{
        .kind = .pane,
        .closed_at = 0,
        .window_id = 0,
        .tab_uuid = null,
        .index = 0,
        .col_width = 0,
        .col_tabbed = false,
        .sessions = @constCast("1234abcd-12ab-469f-a165-70867728950f"),
        .json = @constCast("{}"),
    };
    try testing.expect(allKnownUnreachable(stale_entry));

    const alive_entry: Entry = .{
        .kind = .pane,
        .closed_at = 0,
        .window_id = 0,
        .tab_uuid = null,
        .index = 0,
        .col_width = 0,
        .col_tabbed = false,
        .sessions = @constCast("0f8fad5b-d9cb-469f-a165-70867728950e"),
        .json = @constCast("{}"),
    };
    try testing.expect(!allKnownUnreachable(alive_entry));

    // A fresh close absent from the last scan is not "known unreachable".
    const fresh_entry: Entry = .{
        .kind = .pane,
        .closed_at = 0,
        .window_id = 0,
        .tab_uuid = null,
        .index = 0,
        .col_width = 0,
        .col_tabbed = false,
        .sessions = @constCast("99999999-8888-4777-8666-555555555555"),
        .json = @constCast("{}"),
    };
    try testing.expect(!allKnownUnreachable(fresh_entry));
}
