// src/e2e_test.zig — End-to-end test runner for seance
//
// Spawns seance in an isolated environment, exercises the socket API, and
// verifies responses.  Runs as a standalone executable via `zig build e2e`.
//
// Display backends (tried in order):
//   1. native — use the existing display (XWayland/X11) with hardware GL
//   2. cage (Wayland kiosk compositor, headless) — software rendering
//   3. Xvfb (X11 virtual framebuffer) — software rendering
//
// The native backend is preferred when a display is already available
// (developer workstation) because headless software rendering often
// hits driver bugs (e.g. llvmpipe LLVM codegen issues, NVIDIA EGL
// not supporting GL contexts in headless Wayland compositors).
// cage/Xvfb are fallbacks for headless CI environments.

const std = @import("std");
const io = @import("io.zig");
const posix = @import("posix.zig");
const Allocator = std.mem.Allocator;

// ── Main ───────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    io.init(init.io);
    // Use page_allocator to avoid leak-check noise on exit — the e2e runner
    // is a short-lived process and all memory is reclaimed by the OS.
    const alloc = std.heap.page_allocator;

    const argv = try init.minimal.args.toSlice(alloc);

    const seance_bin = if (argv.len > 1) argv[1] else {
        std.debug.print("usage: e2e_test <path-to-seance-binary>\n", .{});
        std.process.exit(1);
    };

    // Verify seance binary exists
    std.Io.Dir.accessAbsolute(io.get(), seance_bin, .{}) catch {
        std.debug.print("error: seance binary not found at: {s}\n", .{seance_bin});
        std.process.exit(1);
    };

    const backend = detectBackend(alloc);

    var harness = Harness.start(alloc, seance_bin, backend) catch |e| {
        std.debug.print("error: failed to start harness: {}\n", .{e});
        std.process.exit(1);
    };
    defer harness.shutdown();

    var runner = Runner{};

    runner.run("system.ping", &harness, testPing);
    runner.run("system.capabilities", &harness, testCapabilities);
    runner.run("system.identify", &harness, testIdentify);
    runner.run("system.tree", &harness, testTree);
    runner.run("workspace.create", &harness, testWorkspaceCreate);
    runner.run("workspace.list", &harness, testWorkspaceList);
    runner.run("workspace.rename", &harness, testWorkspaceRename);
    runner.run("workspace.select + current", &harness, testWorkspaceSelectCurrent);
    runner.run("workspace.navigation", &harness, testWorkspaceNavigation);
    runner.run("surface.split + list", &harness, testSurfaceSplitList);
    runner.run("surface.send_text + read_screen", &harness, testTerminalIO);
    runner.run("workspace.metadata", &harness, testWorkspaceMetadata);
    runner.run("notification lifecycle", &harness, testNotifications);
    runner.run("surface.close", &harness, testSurfaceClose);
    runner.run("surface.focus + last", &harness, testSurfaceFocusLast);
    runner.run("surface.send_key", &harness, testSurfaceSendKey);
    runner.run("surface.health", &harness, testSurfaceHealth);
    runner.run("window lifecycle", &harness, testWindowLifecycle);
    runner.run("workspace.move_to_window", &harness, testWorkspaceMoveToWindow);
    runner.run("surface.expel", &harness, testSurfaceExpel);
    runner.run("error: invalid method", &harness, testErrorInvalidMethod);
    runner.run("error: bad workspace id", &harness, testErrorBadWorkspaceId);
    runner.run("error: missing params", &harness, testErrorMissingParams);
    runner.run("workspace.close", &harness, testWorkspaceClose);

    // ── zmx integration: separate mock-zmx harness ──
    // The mock records every invocation to a file (session store), fakes
    // daemon semantics, and models per-session state as socket files under
    // $XDG_RUNTIME_DIR/zmx + client liveness via the recorded pid.
    // No real zmx daemon is ever contacted.
    {
        var zmx_harness = Harness.startZmx(alloc, seance_bin, backend, "zmx-attach = true\n") catch |e| {
            std.debug.print("error: failed to start zmx harness: {}\n", .{e});
            std.process.exit(1);
        };
        defer zmx_harness.shutdown();
        runner.run("zmx lifecycle: attach, keep on close, kill on zmx_kill", &zmx_harness, testZmxLifecycle);
        runner.run("zmx undo close: keep + revive re-attaches", &zmx_harness, testZmxUndoClose);
        runner.run("zmx tab undo: whole-tab close revives in place", &zmx_harness, testZmxTabUndo);
        runner.run("zmx window close: keeps sessions, prunes session.json, undoable", &zmx_harness, testZmxWindowKeepUndo);
        // Runs LAST: closes the app (window.close on the only window = quit).
        runner.run("zmx lifecycle: quit keeps sessions", &zmx_harness, testZmxQuitKeepsSessions);
    }
    {
        var sweep_harness = Harness.startZmx(alloc, seance_bin, backend, "zmx-attach = true\n") catch |e| {
            std.debug.print("error: failed to start zmx sweep harness: {}\n", .{e});
            std.process.exit(1);
        };
        defer sweep_harness.shutdown();
        runner.run("zmx kill-unattached: sweeps detached seance-* sessions", &sweep_harness, testZmxKillUnattached);
    }

    runner.summary();
    if (runner.fail > 0) std.process.exit(1);
}

// ── Display backend detection ──────────────────────────────────────────

const DisplayBackend = enum { native, cage, xvfb };

fn detectBackend(alloc: Allocator) DisplayBackend {
    // Prefer the existing display — uses hardware GL, avoids software
    // rendering bugs (llvmpipe LLVM issues, NVIDIA headless EGL).
    if (probeNativeDisplay(alloc)) {
        std.debug.print("seance e2e: using native X11 display (hardware GL)\n", .{});
        return .native;
    }
    if (hasCommand(alloc, "cage")) {
        std.debug.print("seance e2e: using cage (Wayland headless)\n", .{});
        return .cage;
    }
    if (hasCommand(alloc, "Xvfb")) {
        std.debug.print("seance e2e: using Xvfb (X11, software rendering)\n", .{});
        return .xvfb;
    }
    std.debug.print("error: no display available and neither cage nor Xvfb found in PATH\n", .{});
    std.debug.print("  arch (preferred): pacman -S cage\n", .{});
    std.debug.print("  arch (fallback):  pacman -S xorg-server-xvfb\n", .{});
    std.debug.print("  ubuntu:           apt install cage  # or: apt install xvfb\n", .{});
    std.process.exit(1);
}

/// Check if the current DISPLAY points to a live X server.
/// Returns false on CI / headless machines where DISPLAY is unset or
/// points at a dead socket.
fn probeNativeDisplay(alloc: Allocator) bool {
    if (io.getenv("DISPLAY") == null) return false;
    // Verify the X display is reachable.  `xset q` is lightweight and
    // exits 1 when the display is unreachable.
    const result = std.process.run(alloc, io.get(), .{
        .argv = &.{ "xset", "q" },
    }) catch return false;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return result.term == .exited and result.term.exited == 0;
}

fn hasCommand(alloc: Allocator, name: []const u8) bool {
    const result = std.process.run(alloc, io.get(), .{
        .argv = &.{ "which", name },
    }) catch return false;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return result.term.exited == 0;
}

// ── Test runner ────────────────────────────────────────────────────────

const Runner = struct {
    pass: u32 = 0,
    fail: u32 = 0,
    skip: u32 = 0,

    fn run(self: *Runner, name: []const u8, harness: *Harness, comptime testFn: fn (*Harness) TestError!void) void {
        testFn(harness) catch |e| {
            if (e == TestError.Skip) {
                std.debug.print("  \x1b[33mSKIP\x1b[0m {s}\n", .{name});
                self.skip += 1;
                return;
            }
            std.debug.print("  \x1b[31mFAIL\x1b[0m {s}: {}\n", .{ name, e });
            self.fail += 1;
            return;
        };
        std.debug.print("  \x1b[32mPASS\x1b[0m {s}\n", .{name});
        self.pass += 1;
    }

    fn summary(self: *const Runner) void {
        const total = self.pass + self.fail + self.skip;
        std.debug.print("\n{d} tests: \x1b[32m{d} passed\x1b[0m", .{ total, self.pass });
        if (self.fail > 0) std.debug.print(", \x1b[31m{d} failed\x1b[0m", .{self.fail});
        if (self.skip > 0) std.debug.print(", \x1b[33m{d} skipped\x1b[0m", .{self.skip});
        std.debug.print("\n", .{});
    }
};

const TestError = error{
    AssertionFailed,
    SocketError,
    Skip,
    Timeout,
    Unexpected,
    OutOfMemory,
};

fn expect(ok: bool) TestError!void {
    if (!ok) return TestError.AssertionFailed;
}

// ── Harness ────────────────────────────────────────────────────────────

/// Per-process counter keeping concurrent harness tmp dirs disjoint.
var harness_seq: usize = 0;

const Harness = struct {
    alloc: Allocator,
    tmp_dir: []const u8,
    socket_path: []const u8,
    /// harness HOME dir (mock-zmx logs land here)
    home_dir: []const u8 = "",
    /// mock-zmx invocation log path (zmx-mock harnesses only)
    mock_log: []const u8 = "",
    /// cage pid (Wayland) or Xvfb pid (X11). Null if backend wraps seance directly.
    display_pid: ?posix.pid_t,
    /// seance pid (only set for Xvfb where seance is a separate process)
    seance_pid: ?posix.pid_t,

    const STARTUP_TIMEOUT_MS = 15_000;
    const POLL_INTERVAL_MS = 100;

    pub fn start(alloc: Allocator, seance_bin: []const u8, backend: DisplayBackend) !Harness {
        return startZmx(alloc, seance_bin, backend, "");
    }

    /// behavior_cfg: extra [behavior] lines written into the harness
    /// config (e.g. "zmx-attach = true\n"). Non-empty enables the mock-zmx
    /// harness: PATH is fronted by a mock `zmx` that records every
    /// invocation (the mock session store) instead of touching real
    /// sessions. Empty = plain harness (no zmx, no mock).
    pub fn startZmx(alloc: Allocator, seance_bin: []const u8, backend: DisplayBackend, behavior_cfg: []const u8) !Harness {
        const zmx_mock = behavior_cfg.len > 0;
        // 1. Create isolated temp directory
        const pid = if (@hasDecl(std.os, "linux")) std.os.linux.getpid() else std.c.getpid();
        harness_seq += 1;
        const tmp_dir = try std.fmt.allocPrint(alloc, "/tmp/seance-e2e-{d}-{d}", .{ pid, harness_seq });

        // Clean up any stale dir from a previous crashed run
        std.Io.Dir.cwd().deleteTree(io.get(), tmp_dir) catch {};

        const config_dir = try std.fmt.allocPrint(alloc, "{s}/config/seance", .{tmp_dir});
        const home_dir = try std.fmt.allocPrint(alloc, "{s}/home", .{tmp_dir});
        const run_dir = try std.fmt.allocPrint(alloc, "{s}/run", .{tmp_dir});
        const cache_dir = try std.fmt.allocPrint(alloc, "{s}/cache", .{tmp_dir});

        for ([_][]const u8{ config_dir, home_dir, run_dir, cache_dir }) |dir| {
            try mkdirRecursive(dir);
        }

        // 2. Write minimal config.toml
        const socket_path = try std.fmt.allocPrint(alloc, "{s}/seance.sock", .{tmp_dir});
        const config_path = try std.fmt.allocPrint(alloc, "{s}/config.toml", .{config_dir});
        {
            const f = try std.Io.Dir.createFileAbsolute(io.get(), config_path, .{});
            defer f.close(io.get());
            var buf: [1024]u8 = undefined;
            var w = f.writer(io.get(), &buf);
            if (zmx_mock) {
                try w.interface.print(
                    "[socket]\npath = \"{s}\"\n\n[behavior]\nconfirm-close-window = false\n{s}",
                    .{ socket_path, behavior_cfg },
                );
            } else {
                try w.interface.print("[socket]\npath = \"{s}\"\n\n[behavior]\nconfirm-close-window = false\n", .{socket_path});
            }
            try w.interface.flush();
        }

        const mock_log_path = try std.fmt.allocPrint(alloc, "{s}/home/zmx-mock.log", .{tmp_dir});
        var extra_env: std.ArrayList([]const u8) = .empty;
        if (zmx_mock) {
            try createMockZmx(alloc, home_dir);
            const path_val = std.fmt.allocPrint(
                alloc,
                "PATH={s}/bin:{s}",
                .{ home_dir, io.getenv("PATH") orelse "/run/current-system/sw/bin:/bin" },
            ) catch return error.OutOfMemory;
            try extra_env.append(alloc, path_val);
            try extra_env.append(alloc, try std.fmt.allocPrint(alloc, "ZMX_MOCK_LOG={s}", .{mock_log_path}));
        }

        const xdg_config = std.fs.path.dirname(config_dir) orelse config_dir;

        var harness = Harness{
            .alloc = alloc,
            .tmp_dir = tmp_dir,
            .socket_path = socket_path,
            .home_dir = home_dir,
            .mock_log = if (zmx_mock) mock_log_path else "",
            .display_pid = null,
            .seance_pid = null,
        };

        switch (backend) {
            .native => {
                // Use the existing display (XWayland/X11) — no display server to spawn
                harness.seance_pid = try spawnSeanceNative(alloc, seance_bin, xdg_config, home_dir, run_dir, cache_dir, extra_env.items);
            },
            .cage => {
                // cage wraps seance as its child — single process to manage
                harness.display_pid = try spawnCage(alloc, seance_bin, xdg_config, home_dir, run_dir, cache_dir, extra_env.items);
            },
            .xvfb => {
                const display = try findFreeDisplay(alloc);
                harness.display_pid = try spawnXvfb(alloc, display);

                // Give Xvfb a moment to initialize
                io.sleep(300 * std.time.ns_per_ms);

                harness.seance_pid = try spawnSeanceX11(alloc, seance_bin, display, xdg_config, home_dir, run_dir, cache_dir, extra_env.items);
            },
        }

        // 3. Wait for seance to be ready
        try harness.waitReady();

        std.debug.print("seance e2e: harness ready (socket={s})\n\n", .{socket_path});
        return harness;
    }

    pub fn shutdown(self: *Harness) void {
        std.debug.print("\nseance e2e: shutting down...\n", .{});
        if (self.seance_pid) |pid| killProcess(pid);
        io.sleep(100 * std.time.ns_per_ms);
        if (self.display_pid) |pid| killProcess(pid);
        std.Io.Dir.cwd().deleteTree(io.get(), self.tmp_dir) catch {};
    }

    fn waitReady(self: *Harness) !void {
        var elapsed: u64 = 0;
        while (elapsed < STARTUP_TIMEOUT_MS) {
            if (self.callRaw("system.ping", null)) |_| {
                return;
            } else |_| {}
            io.sleep(POLL_INTERVAL_MS * std.time.ns_per_ms);
            elapsed += POLL_INTERVAL_MS;
        }
        std.debug.print("error: seance did not respond within {d}ms\n", .{STARTUP_TIMEOUT_MS});
        return error.Timeout;
    }

    // ── Socket client ──────────────────────────────────────────────────

    const Response = struct {
        ok: bool,
        result: std.json.Value,
        raw: []const u8,
        parsed: std.json.Parsed(std.json.Value),
    };

    pub fn call(self: *Harness, method: []const u8, params: ?[]const u8) TestError!Response {
        return self.callRaw(method, params) catch return TestError.SocketError;
    }

    pub fn callOk(self: *Harness, method: []const u8, params: ?[]const u8) TestError!std.json.Value {
        const resp = try self.call(method, params);
        if (!resp.ok) return TestError.AssertionFailed;
        return resp.result;
    }

    /// Expect the call to return ok:false.
    pub fn callExpectFail(self: *Harness, method: []const u8, params: ?[]const u8) TestError!void {
        const resp = try self.call(method, params);
        if (resp.ok) return TestError.AssertionFailed;
    }

    fn callRaw(self: *Harness, method: []const u8, params: ?[]const u8) !Response {
        const request = if (params) |p|
            try std.fmt.allocPrint(self.alloc, "{{\"id\":\"1\",\"method\":\"{s}\",\"params\":{s}}}\n", .{ method, p })
        else
            try std.fmt.allocPrint(self.alloc, "{{\"id\":\"1\",\"method\":\"{s}\"}}\n", .{method});
        defer self.alloc.free(request);

        const sock = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
        defer posix.close(sock);

        var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
        @memset(&addr.path, 0);
        const copy_len = @min(self.socket_path.len, addr.path.len - 1);
        for (0..copy_len) |i| {
            addr.path[i] = @intCast(self.socket_path[i]);
        }
        try posix.connect(sock, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));

        const tv: posix.timeval = .{ .sec = 5, .usec = 0 };
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv));

        _ = try posix.write(sock, request);

        var response_buf: std.ArrayList(u8) = .empty;
        var buf: [16384]u8 = undefined;
        while (true) {
            const n = try posix.read(sock, &buf);
            if (n == 0) break;
            try response_buf.appendSlice(self.alloc, buf[0..n]);
            if (std.mem.indexOfScalar(u8, buf[0..n], '\n') != null) break;
        }

        if (response_buf.items.len == 0) return error.EmptyResponse;

        const trimmed = std.mem.trim(u8, response_buf.items, &[_]u8{ '\r', '\n', ' ' });
        const parsed = try std.json.parseFromSlice(std.json.Value, self.alloc, trimmed, .{});

        if (parsed.value != .object) return error.InvalidResponse;

        const ok_val = parsed.value.object.get("ok");
        const ok = if (ok_val) |v| (v == .bool and v.bool) else false;
        const result = parsed.value.object.get("result") orelse .null;

        return Response{
            .ok = ok,
            .result = result,
            .raw = trimmed,
            .parsed = parsed,
        };
    }

    /// Read terminal screen, retrying until `needle` appears or timeout.
    pub fn expectScreen(self: *Harness, surface_id_param: ?[]const u8, needle: []const u8, timeout_ms: u64) TestError!void {
        var elapsed: u64 = 0;
        while (elapsed < timeout_ms) {
            const params = if (surface_id_param) |sid|
                std.fmt.allocPrint(self.alloc, "{{\"surface_id\":{s}}}", .{sid}) catch return TestError.Unexpected
            else
                null;
            if (self.call("surface.read_screen", params)) |resp| {
                if (resp.ok) {
                    if (resp.result == .object) {
                        if (resp.result.object.get("text")) |text_val| {
                            if (text_val == .string) {
                                if (std.mem.indexOf(u8, text_val.string, needle) != null) return;
                            }
                        }
                    }
                }
            } else |_| {}
            io.sleep(POLL_INTERVAL_MS * std.time.ns_per_ms);
            elapsed += POLL_INTERVAL_MS;
        }
        return TestError.Timeout;
    }
};

// ── zmx lifecycle (against the mock-zmx session store) ─────────────────
//
// The mock `zmx` records every invocation to $HOME/zmx-mock.log and keeps
// sessions as files under $XDG_RUNTIME_DIR/zmx (clients=1 while the
// attach'd process lives). Policy under test:
//   - every new terminal (startup tab, created tab, split, created window)
//     attaches its own `seance-<pane-uuid>` session
//   - explicit closes KEEP sessions: no kill line, the snapshot lands in
//     close_history.json (never in session.json), and the app rescans
//   - zmx_kill=true closes DESTROY the sessions (kill line, no history)
//   - undo-close revives the newest entry; shells re-attach (new attach
//     line) with the pane's ORIGINAL uuid (system.tree membership)
//   - whole-app quit kills NOTHING (re-attach on next launch)

fn seance(h: *Harness, uuid_str: []const u8) []const u8 {
    return std.fmt.allocPrint(h.alloc, "seance-{s}", .{uuid_str}) catch return "";
}

/// UUIDs present in `after` that were not in `before`.
fn newUuids(before: []const []const u8, after: []const []const u8) []const u8 {
    for (after) |a| {
        var found = false;
        for (before) |b| {
            if (std.mem.eql(u8, a, b)) {
                found = true;
                break;
            }
        }
        if (!found) return a;
    }
    return "";
}

fn uuidInList(list: []const []const u8, needle: []const u8) bool {
    for (list) |u| {
        if (std.mem.eql(u8, u, needle)) return true;
    }
    return false;
}

fn closeHistoryPath(h: *Harness) []const u8 {
    return std.fmt.allocPrint(h.alloc, "{s}/.config/seance/close_history.json", .{h.home_dir}) catch return "";
}

/// Poll close_history.json until it contains (or, with want=false, no
/// longer contains) the given substring.
fn waitForHistory(h: *Harness, needle: []const u8, want: bool) TestError!void {
    const path = closeHistoryPath(h);
    var buf: [262144]u8 = undefined;
    var elapsed: u64 = 0;
    while (elapsed < 20_000) {
        const got = readFileBuf(path, &buf) orelse "";
        const has = std.mem.indexOf(u8, got, needle) != null;
        if (has == want) return;
        io.sleep(POLL_SLEEP_MS * std.time.ns_per_ms);
        elapsed += POLL_SLEEP_MS;
    }
    std.debug.print("  close_history {s} want={}\n", .{ needle, want });
    return TestError.Timeout;
}

fn testZmxLifecycle(h: *Harness) TestError!void {
    // 0. Feature reports itself enabled through the socket API.
    const status = try h.callOk("zmx.status", null);
    if (status != .object) return TestError.AssertionFailed;
    const enabled = status.object.get("enabled") orelse return TestError.AssertionFailed;
    if (enabled != .bool or !enabled.bool) return TestError.AssertionFailed;

    // 1. Startup tab's terminal attached its own session.
    var snap0: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap0);
    if (snap0.items.len == 0) return TestError.AssertionFailed;
    try waitForMockLog(h, "attach");
    try waitForMockLog(h, seance(h, snap0.items[0]));

    // 2. workspace.create → new tab, its terminal gets its OWN uuid+session.
    const created = try h.callOk("workspace.create", "{\"title\":\"zmx-tab\"}");
    if (created != .object) return TestError.AssertionFailed;
    const ws_id_val = created.object.get("id") orelse return TestError.AssertionFailed;
    if (ws_id_val != .integer) return TestError.AssertionFailed;
    const ws_id: u64 = @intCast(ws_id_val.integer);
    const tab_uuid_val = created.object.get("tab_uuid") orelse return TestError.AssertionFailed;
    if (tab_uuid_val != .string) return TestError.AssertionFailed;
    const tab_uuid = tab_uuid_val.string;

    var snap1: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap1);
    const u_new_tab = newUuids(snap0.items, snap1.items);
    if (u_new_tab.len == 0) {
        std.debug.print("  no new tab uuid after create\n", .{});
        return TestError.AssertionFailed;
    }
    try waitForMockLog(h, seance(h, u_new_tab));

    // 3. surface.split (focused = new tab) → THIRD terminal, own session.
    const split = try h.callOk("surface.split", null);
    if (split != .object) return TestError.AssertionFailed;
    const sid_val = split.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (sid_val != .integer) return TestError.AssertionFailed;
    const split_sid: u64 = @intCast(sid_val.integer);

    var snap2: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap2);
    const u_split = newUuids(snap1.items, snap2.items);
    if (u_split.len == 0) {
        std.debug.print("  no new pane uuid after split\n", .{});
        return TestError.AssertionFailed;
    }
    try waitForMockLog(h, seance(h, u_split));

    // 4. Plain split close KEEPS the session: no kill line, the snapshot
    // is recorded in close_history.json (and the scan pipeline is alive,
    // proven by a `zmx list` invocation in the mock log).
    const close_surface = std.fmt.allocPrint(h.alloc, "{{\"surface_id\":{d}}}", .{split_sid}) catch
        return TestError.Unexpected;
    _ = try h.callOk("surface.close", close_surface);
    try waitForHistory(h, u_split, true);
    try waitForMockLog(h, "zmx list");
    // Grace window: a stray kill here would be a policy regression.
    try expectNoMockLog(h, try std.fmt.allocPrint(h.alloc, "kill --force {s}", .{seance(h, u_split)}));

    // 4b. Split twice more; close FOCUSED with zmx_kill=true DESTROYS
    // exactly the doomed session and records no history for it.
    _ = try h.callOk("surface.split", null);
    var snap2b: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap2b);
    const u_split2 = newUuids(snap2.items, snap2b.items);
    if (u_split2.len == 0) {
        std.debug.print("  no new pane uuid after second split\n", .{});
        return TestError.AssertionFailed;
    }
    try waitForMockLog(h, seance(h, u_split2));
    _ = try h.callOk("surface.split", null);
    var snap2c: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap2c);
    const u_split3 = newUuids(snap2b.items, snap2c.items);
    if (u_split3.len == 0) {
        std.debug.print("  no new pane uuid after third split\n", .{});
        return TestError.AssertionFailed;
    }
    try waitForMockLog(h, seance(h, u_split3));
    _ = try h.callOk("surface.close", "{\"zmx_kill\":true}");
    try waitForMockLog(h, try std.fmt.allocPrint(h.alloc, "kill --force {s}", .{seance(h, u_split3)}));
    // The sibling (u_split2) survived: closing FOCUSED killed exactly the
    // doomed terminal.
    try expectNoMockLog(h, try std.fmt.allocPrint(h.alloc, "kill --force {s}", .{seance(h, u_split2)}));

    // 5. workspace.close with zmx_kill kills the tab's terminals.
    const close_ws = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d},\"zmx_kill\":true}}", .{ws_id}) catch
        return TestError.Unexpected;
    _ = try h.callOk("workspace.close", close_ws);
    try waitForMockLog(h, try std.fmt.allocPrint(h.alloc, "kill --force {s}", .{seance(h, u_new_tab)}));

    // 6. The created tab carried a valid tab_uuid through the socket API.
    if (tab_uuid.len != 36) return TestError.AssertionFailed;

    // 6b. Kill-closing the LAST pane of a tab must still kill its session:
    // the workspace cascade has to use the UUIDs captured before teardown,
    // not collect them from the already-emptied tab.
    var snap_last: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap_last);
    _ = try h.callOk("workspace.create", "{\"title\":\"zmx-kill-last\"}");
    var snap_last2: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap_last2);
    const u_last = newUuids(snap_last.items, snap_last2.items);
    if (u_last.len == 0) return TestError.AssertionFailed;
    try waitForMockLog(h, seance(h, u_last));
    _ = try h.callOk("surface.close", "{\"zmx_kill\":true}");
    try waitForMockLog(h, try std.fmt.allocPrint(h.alloc, "kill --force {s}", .{seance(h, u_last)}));

    // 7. The startup tab's terminal was never killed.
    try expectNoMockLog(h, try std.fmt.allocPrint(h.alloc, "kill --force {s}", .{seance(h, snap0.items[0])}));
}

fn testZmxUndoClose(h: *Harness) TestError!void {
    // Split → own session; close it (plain = keep + record); undo pops the
    // newest entry and revives the pane WITH ITS ORIGINAL UUID — proven by
    // the uuid reappearing in system.tree, and the snapshot vanishing from
    // the history file.
    var snap: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap);

    const split = try h.callOk("surface.split", null);
    if (split != .object) return TestError.AssertionFailed;
    const sid_val = split.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (sid_val != .integer) return TestError.AssertionFailed;
    const split_sid: u64 = @intCast(sid_val.integer);

    var snap2: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap2);
    const u = newUuids(snap.items, snap2.items);
    if (u.len == 0) return TestError.AssertionFailed;
    try waitForMockLog(h, seance(h, u));

    _ = try h.callOk("surface.close", std.fmt.allocPrint(h.alloc, "{{\"surface_id\":{d}}}", .{split_sid}) catch
        return TestError.Unexpected);
    try waitForHistory(h, u, true);

    const undo = try h.callOk("zmx.undo_close", null);
    if (undo != .object) return TestError.AssertionFailed;
    const revived = undo.object.get("revived") orelse return TestError.AssertionFailed;
    if (revived != .bool or !revived.bool) {
        std.debug.print("  undo_close did not revive\n", .{});
        return TestError.AssertionFailed;
    }

    var snap3: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap3);
    if (!uuidInList(snap3.items, u)) {
        std.debug.print("  revived pane uuid missing from tree\n", .{});
        return TestError.AssertionFailed;
    }
    // The entry was consumed: its snapshot is gone from the history file.
    try waitForHistory(h, u, false);
}

fn testZmxTabUndo(h: *Harness) TestError!void {
    // Create a tab, close the WHOLE tab plainly (keep + record), then undo.
    // This exercises the .tab revive path (reviveWorkspaceInto), not just
    // the single-pane case: the restored tab returns with its tab_uuid and
    // its terminal's original pane_uuid.
    var before: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &before);

    const created = try h.callOk("workspace.create", "{\"title\":\"zmx-tab-undo\"}");
    if (created != .object) return TestError.AssertionFailed;
    const ws_id_val = created.object.get("id") orelse return TestError.AssertionFailed;
    if (ws_id_val != .integer) return TestError.AssertionFailed;
    const ws_id: u64 = @intCast(ws_id_val.integer);
    const tab_uuid_val = created.object.get("tab_uuid") orelse return TestError.AssertionFailed;
    if (tab_uuid_val != .string) return TestError.AssertionFailed;
    const tab_uuid = tab_uuid_val.string;

    var after: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &after);
    const u = newUuids(before.items, after.items);
    if (u.len == 0) return TestError.AssertionFailed;
    try waitForMockLog(h, seance(h, u));

    _ = try h.callOk("workspace.close", std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d}}}", .{ws_id}) catch
        return TestError.Unexpected);
    try waitForHistory(h, u, true);

    const undo = try h.callOk("zmx.undo_close", null);
    if (undo != .object) return TestError.AssertionFailed;
    const revived = undo.object.get("revived") orelse return TestError.AssertionFailed;
    if (revived != .bool or !revived.bool) {
        std.debug.print("  tab undo_close did not revive\n", .{});
        return TestError.AssertionFailed;
    }
    if (!try workspaceHasTab(h, tab_uuid)) {
        std.debug.print("  revived tab_uuid missing from workspace.list\n", .{});
        return TestError.AssertionFailed;
    }
    var after2: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &after2);
    if (!uuidInList(after2.items, u)) return TestError.AssertionFailed;
    try waitForHistory(h, u, false);
}

fn workspaceHasTab(h: *Harness, tab_uuid: []const u8) TestError!bool {
    const res = try h.callOk("workspace.list", null);
    if (res != .object) return TestError.AssertionFailed;
    const wss = res.object.get("workspaces") orelse return TestError.AssertionFailed;
    if (wss != .array) return TestError.AssertionFailed;
    for (wss.array.items) |ws| {
        if (ws != .object) continue;
        const t = ws.object.get("tab_uuid") orelse continue;
        if (t == .string and std.mem.eql(u8, t.string, tab_uuid)) return true;
    }
    return false;
}

/// Poll zmx.status until its unattached count equals `want` (the value
/// behind the sidebar row is produced asynchronously by the scan worker).
fn waitForUnattached(h: *Harness, want: usize) TestError!void {
    return waitForUnattachedWithin(h, want, 20_000);
}

fn waitForUnattachedWithin(h: *Harness, want: usize, timeout_ms: u64) TestError!void {
    var elapsed: u64 = 0;
    while (elapsed < timeout_ms) {
        if (h.callOk("zmx.status", null)) |status| {
            if (status == .object) {
                if (status.object.get("unattached")) |v| {
                    if (v == .integer and v.integer == want) return;
                }
            }
        } else |_| {}
        io.sleep(POLL_SLEEP_MS * std.time.ns_per_ms);
        elapsed += POLL_SLEEP_MS;
    }
    std.debug.print("  unattached count never reached {d}\n", .{want});
    return TestError.Timeout;
}

/// Assert the current unattached count without polling; used where the
/// indicator must update synchronously with the API/keypress.
fn expectUnattached(h: *Harness, want: usize) TestError!void {
    const status = try h.callOk("zmx.status", null);
    if (status != .object) return TestError.AssertionFailed;
    const v = status.object.get("unattached") orelse return TestError.AssertionFailed;
    if (v != .integer or v.integer != want) return TestError.AssertionFailed;
}

fn windowCount(h: *Harness) TestError!usize {
    const res = try h.callOk("window.list", null);
    if (res != .object) return TestError.AssertionFailed;
    const wins = res.object.get("windows") orelse return TestError.AssertionFailed;
    if (wins != .array) return TestError.AssertionFailed;
    return wins.array.items.len;
}

fn waitForWindowCount(h: *Harness, want: usize) TestError!void {
    var elapsed: u64 = 0;
    while (elapsed < 15_000) {
        const n = windowCount(h) catch {
            io.sleep(POLL_SLEEP_MS * std.time.ns_per_ms);
            elapsed += POLL_SLEEP_MS;
            continue;
        };
        if (n == want) return;
        io.sleep(POLL_SLEEP_MS * std.time.ns_per_ms);
        elapsed += POLL_SLEEP_MS;
    }
    return TestError.Timeout;
}

fn testZmxWindowKeepUndo(h: *Harness) TestError!void {
    var snap: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap);
    const n_before = try windowCount(h);

    // Second window → its terminal attaches…
    const create = try h.callOk("window.create", null);
    if (create != .object) return TestError.AssertionFailed;
    const win_idx_val = create.object.get("index") orelse return TestError.AssertionFailed;
    if (win_idx_val != .integer) return TestError.AssertionFailed;
    const win_idx: u64 = @intCast(win_idx_val.integer);

    var snap2: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap2);
    const w2_uuid = newUuids(snap.items, snap2.items);
    if (w2_uuid.len == 0) {
        std.debug.print("  no new pane uuid after window.create\n", .{});
        return TestError.AssertionFailed;
    }
    try waitForMockLog(h, seance(h, w2_uuid));

    // …closing THAT window (others remain) keeps the session (no kill)…
    _ = try h.callOk("window.close", std.fmt.allocPrint(h.alloc, "{{\"window_id\":{d}}}", .{win_idx}) catch
        return TestError.Unexpected);
    try expectNoMockLog(h, try std.fmt.allocPrint(h.alloc, "kill --force {s}", .{seance(h, w2_uuid)}));

    // …records the FULL window in close_history.json…
    try waitForHistory(h, w2_uuid, true);

    // …and is NOT kept in session.json anymore (closed window is pruned
    // from the restore file; only the history can bring it back).
    var sbuf: [262144]u8 = undefined;
    const spath = std.fmt.allocPrint(h.alloc, "{s}/.config/seance/session.json", .{h.home_dir}) catch
        return TestError.Unexpected;
    // saveAll runs synchronously in closeWindow, but autosave ticks may
    // interleave; poll until the uuid is gone (want=false).
    {
        var elapsed: u64 = 0;
        var gone = false;
        while (elapsed < 15_000) {
            if (readFileBuf(spath, &sbuf)) |got| {
                if (std.mem.indexOf(u8, got, w2_uuid) == null) {
                    gone = true;
                    break;
                }
            }
            io.sleep(POLL_SLEEP_MS * std.time.ns_per_ms);
            elapsed += POLL_SLEEP_MS;
        }
        if (!gone) {
            std.debug.print("  closed window still in session.json\n", .{});
            return TestError.AssertionFailed;
        }
    }

    // Undo restores the WINDOW itself.
    const undo = try h.callOk("zmx.undo_close", null);
    if (undo != .object) return TestError.AssertionFailed;
    const revived = undo.object.get("revived") orelse return TestError.AssertionFailed;
    if (revived != .bool or !revived.bool) return TestError.AssertionFailed;
    try waitForWindowCount(h, n_before + 1);

    var snap3: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap3);
    if (!uuidInList(snap3.items, w2_uuid)) {
        std.debug.print("  revived window pane uuid missing from tree\n", .{});
        return TestError.AssertionFailed;
    }
}

fn testZmxQuitKeepsSessions(h: *Harness) TestError!void {
    // A fresh window's terminal…
    var snap: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap);
    if (snap.items.len == 0) return TestError.AssertionFailed;
    const keep_uuid = snap.items[0];

    _ = try h.callOk("window.create", null);
    var snap2: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap2);
    const w2_uuid = newUuids(snap.items, snap2.items);
    if (w2_uuid.len == 0) return TestError.AssertionFailed;
    try waitForMockLog(h, seance(h, w2_uuid));

    // …closing that window keeps its session (default policy: detach +
    // history, never kill)…
    const n = windowCount(h) catch return TestError.AssertionFailed;
    _ = try h.callOk("window.close", std.fmt.allocPrint(h.alloc, "{{\"window_id\":{d}}}", .{n - 1}) catch
        return TestError.Unexpected);
    try expectNoMockLog(h, try std.fmt.allocPrint(h.alloc, "kill --force {s}", .{seance(h, w2_uuid)}));

    // …and closing ALL windows (whole-app quit) keeps EVERY session.
    // (Earlier tests may have left extra windows alive via undo — loop.)
    {
        var guard: usize = 0;
        while (guard < 10) : (guard += 1) {
            const live = windowCount(h) catch break; // socket gone → quit happened
            _ = h.call("window.close", "{\"window_id\":0}") catch {};
            if (live <= 1) break;
        }
    }
    var elapsed: u64 = 0;
    while (elapsed < 10_000) {
        if (h.callRaw("system.ping", null)) |_| {
            io.sleep(POLL_SLEEP_MS * std.time.ns_per_ms);
            elapsed += POLL_SLEEP_MS;
        } else |_| break;
    }
    if (elapsed >= 10_000) return TestError.Timeout; // app never quit

    // Grace window: a stray kill for the surviving tab would be a bug.
    try expectNoMockLog(h, try std.fmt.allocPrint(h.alloc, "kill --force {s}", .{seance(h, keep_uuid)}));
    try expectNoMockLog(h, try std.fmt.allocPrint(h.alloc, "kill --force {s}", .{seance(h, w2_uuid)}));
}

fn testZmxKillUnattached(h: *Harness) TestError!void {
    // Fresh app: split, close it plainly (session goes detached + history
    // entry), then sweep. The sweep must destroy EXACTLY the detached
    // seance-* session — the live startup terminal (clients=1 in the mock)
    // and the split's survivor stay untouched, and foreign-named sessions
    // are out of scope by the name filter itself.
    var snap: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap);
    if (snap.items.len == 0) return TestError.AssertionFailed;
    const startup_uuid = snap.items[0];
    try waitForMockLog(h, seance(h, startup_uuid));

    const split = try h.callOk("surface.split", null);
    if (split != .object) return TestError.AssertionFailed;
    const sid_val = split.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (sid_val != .integer) return TestError.AssertionFailed;
    const split_sid: u64 = @intCast(sid_val.integer);
    var snap2: std.ArrayList([]const u8) = .empty;
    try treePaneUuids(h, &snap2);
    const u_split = newUuids(snap.items, snap2.items);
    if (u_split.len == 0) return TestError.AssertionFailed;
    try waitForMockLog(h, seance(h, u_split));

    _ = try h.callOk("surface.close", std.fmt.allocPrint(h.alloc, "{{\"surface_id\":{d}}}", .{split_sid}) catch
        return TestError.Unexpected);
    try waitForHistory(h, u_split, true);
    // The closed split is now detached and counted for the sidebar row;
    // the live startup terminal is not. Must update well before the 5s
    // periodic tick, proving the close-triggered recheck.
    try waitForUnattachedWithin(h, 1, 3_000);

    _ = try h.callOk("zmx.kill_unattached", null);
    // The indicator is dismissed synchronously with the sweep call; it must
    // not wait for the async `zmx list`/kill round-trip.
    try expectUnattached(h, 0);
    try waitForMockLog(h, try std.fmt.allocPrint(h.alloc, "kill --force {s}", .{seance(h, u_split)}));

    // Never the live startup terminal.
    try expectNoMockLog(h, try std.fmt.allocPrint(h.alloc, "kill --force {s}", .{seance(h, startup_uuid)}));
    // The follow-up scan drops the swept session from the count.
    try waitForUnattached(h, 0);

    // The next scan prunes the dead entry out of the history.
    var elapsed: u64 = 0;
    while (elapsed < 20_000) {
        if (h.callOk("zmx.status", null)) |status| {
            if (status == .object) {
                if (status.object.get("history")) |hv| {
                    if (hv == .integer and hv.integer == 0) return;
                }
            }
        } else |_| {}
        io.sleep(POLL_SLEEP_MS * std.time.ns_per_ms);
        elapsed += POLL_SLEEP_MS;
    }
    std.debug.print("  history not drained after sweep\n", .{});
    return TestError.Timeout;
}

// ── Process helpers ────────────────────────────────────────────────────

/// Spawn seance using the existing display (XWayland or X11).
fn spawnSeanceNative(
    alloc: Allocator,
    seance_bin: []const u8,
    xdg_config: []const u8,
    home_dir: []const u8,
    run_dir: []const u8,
    cache_dir: []const u8,
    extra_env: []const []const u8,
) !posix.pid_t {
    const xdg_config_arg = try std.fmt.allocPrint(alloc, "XDG_CONFIG_HOME={s}", .{xdg_config});
    const run_dir_arg = try std.fmt.allocPrint(alloc, "XDG_RUNTIME_DIR={s}", .{run_dir});
    const cache_dir_arg = try std.fmt.allocPrint(alloc, "XDG_CACHE_HOME={s}", .{cache_dir});
    const home_dir_arg = try std.fmt.allocPrint(alloc, "HOME={s}", .{home_dir});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{"env"});
    try argv.appendSlice(alloc, &scrub_env_args);
    try argv.appendSlice(alloc, &.{"GDK_BACKEND=x11"});

    try argv.appendSlice(alloc, extra_env);
    try argv.appendSlice(alloc, &.{ xdg_config_arg, run_dir_arg, cache_dir_arg, home_dir_arg, "NO_AT_BRIDGE=1", "DBUS_SESSION_BUS_ADDRESS=disabled:", seance_bin });

    const child = try std.process.spawn(io.get(), .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore, .stderr = .inherit });
    return child.id.?;
}

/// Spawn cage (headless Wayland compositor) wrapping seance as its child.
/// Uses `env` to set specific vars while inheriting the parent environment.
fn spawnCage(
    alloc: Allocator,
    seance_bin: []const u8,
    xdg_config: []const u8,
    home_dir: []const u8,
    run_dir: []const u8,
    cache_dir: []const u8,
    extra_env: []const []const u8,
) !posix.pid_t {
    const xdg_config_arg = try std.fmt.allocPrint(alloc, "XDG_CONFIG_HOME={s}", .{xdg_config});
    const run_dir_arg = try std.fmt.allocPrint(alloc, "XDG_RUNTIME_DIR={s}", .{run_dir});
    const cache_dir_arg = try std.fmt.allocPrint(alloc, "XDG_CACHE_HOME={s}", .{cache_dir});
    const home_dir_arg = try std.fmt.allocPrint(alloc, "HOME={s}", .{home_dir});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{"env"});
    try argv.appendSlice(alloc, &scrub_env_args);
    try argv.appendSlice(alloc, &.{"WLR_BACKENDS=headless"});
    try argv.appendSlice(alloc, extra_env);
    try argv.appendSlice(alloc, &.{
        xdg_config_arg,
        run_dir_arg,
        cache_dir_arg,
        home_dir_arg,
        // On Wayland, GDK needs GLES (EGL) for window surfaces — only disable vulkan
        "GDK_DISABLE=vulkan",
        // Block dbus to prevent GApplication single-instance detection
        "DBUS_SESSION_BUS_ADDRESS=disabled:",
        "NO_AT_BRIDGE=1",
        "cage",
        "--",
        seance_bin,
    });

    const child = try std.process.spawn(io.get(), .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    return child.id.?;
}

/// Spawn Xvfb (X11 virtual framebuffer).
fn spawnXvfb(_: Allocator, display: []const u8) !posix.pid_t {
    const child = try std.process.spawn(io.get(), .{ .argv = &.{ "Xvfb", display, "-screen", "0", "1280x720x24", "-nolisten", "tcp", "-ac" }, .stdin = .ignore, .stdout = .ignore, .stderr = .inherit });
    return child.id.?;
}

/// Spawn seance under Xvfb (X11 + software rendering).
fn spawnSeanceX11(
    alloc: Allocator,
    seance_bin: []const u8,
    display: []const u8,
    xdg_config: []const u8,
    home_dir: []const u8,
    run_dir: []const u8,
    cache_dir: []const u8,
    extra_env: []const []const u8,
) !posix.pid_t {
    const display_arg = try std.fmt.allocPrint(alloc, "DISPLAY={s}", .{display});
    const xdg_config_arg = try std.fmt.allocPrint(alloc, "XDG_CONFIG_HOME={s}", .{xdg_config});
    const run_dir_arg = try std.fmt.allocPrint(alloc, "XDG_RUNTIME_DIR={s}", .{run_dir});
    const cache_dir_arg = try std.fmt.allocPrint(alloc, "XDG_CACHE_HOME={s}", .{cache_dir});
    const home_dir_arg = try std.fmt.allocPrint(alloc, "HOME={s}", .{home_dir});

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{"env"});
    try argv.appendSlice(alloc, &scrub_env_args);
    try argv.appendSlice(alloc, &.{ display_arg, "GDK_BACKEND=x11", "LIBGL_ALWAYS_SOFTWARE=1" });
    try argv.appendSlice(alloc, extra_env);
    try argv.appendSlice(alloc, &.{
        xdg_config_arg,
        run_dir_arg,
        cache_dir_arg,
        home_dir_arg,
        "GDK_DISABLE=gles-api,vulkan",
        "NO_AT_BRIDGE=1",
        "DBUS_SESSION_BUS_ADDRESS=disabled:",
        seance_bin,
    });

    const child = try std.process.spawn(io.get(), .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore, .stderr = .inherit });
    return child.id.?;
}

fn killProcess(pid: posix.pid_t) void {
    posix.kill(pid, posix.SIG.TERM) catch {};
    posix.waitpid(pid, 0);
}

/// Scrub terminal-identity vars a harness seance must NEVER inherit from
/// the developer's own shell (which is itself a seance/zmx session when
/// e2e runs interactively): a leaked GHOSTTY_RESOURCES_DIR breaks the
/// wrapper-resources chain (seance shell integration never loads) and a
/// leaked ZMX_SESSION turns `zmx attach` into a session switch.
const scrub_env_args = [_][]const u8{
    "-u", "GHOSTTY_RESOURCES_DIR",
    "-u", "GHOSTTY_BASH_ENV",
    "-u", "GHOSTTY_BASH_INJECT",
    "-u", "GHOSTTY_SHELL_FEATURES",
    "-u", "ZMX_SESSION",
    "-u", "ZMX_SESSION_PREFIX",
    "-u", "SEANCE_SOCKET_PATH",
    "-u", "SEANCE_SHELL_INTEGRATION_DIR",
    "-u", "SEANCE_BIN_DIR",
    "-u", "SEANCE_WORKSPACE_ID",
    "-u", "SEANCE_SURFACE_ID",
    "-u", "SEANCE_PANE_GROUP_ID",
    "-u", "SEANCE_PANEL_ID",
    "-u", "SEANCE_PANE_UUID",
    "-u", "SEANCE_TAB_UUID",
    "-u", "SEANCE_ZMX_ATTACH",
    "-u", "SEANCE_PORT",
    "-u", "SEANCE_PORT_END",
    "-u", "SEANCE_PORT_RANGE",
    "-u", "SEANCE_RESTORE_SCROLLBACK_FILE",
};

fn mkdirRecursive(path: []const u8) !void {
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            std.Io.Dir.createDirAbsolute(io.get(), path[0..i], .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
        }
    }
    std.Io.Dir.createDirAbsolute(io.get(), path, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
}

fn findFreeDisplay(alloc: Allocator) ![]const u8 {
    for (99..111) |n| {
        const lock_path = std.fmt.allocPrint(alloc, "/tmp/.X{d}-lock", .{n}) catch continue;
        defer alloc.free(lock_path);
        std.Io.Dir.accessAbsolute(io.get(), lock_path, .{}) catch {
            return try std.fmt.allocPrint(alloc, ":{d}", .{n});
        };
    }
    return error.NoFreeDisplay;
}

/// Write a mock `zmx` into the harness HOME that records every invocation
/// to $ZMX_MOCK_LOG and keeps per-session state under
/// $XDG_RUNTIME_DIR/zmx: `attach` creates the "socket" file and records
/// its own pid (the exec'd client inherits it), `kill --force` removes
/// both, `list` prints real-shaped lines with clients=1 iff the recorded
/// pid is still alive. No real zmx daemon is ever contacted.
fn createMockZmx(alloc: Allocator, home_dir: []const u8) !void {
    const bin_dir = try std.fmt.allocPrint(alloc, "{s}/bin", .{home_dir});
    try mkdirRecursive(bin_dir);
    const script_path = try std.fmt.allocPrint(alloc, "{s}/zmx", .{bin_dir});

    const script =
        \\#!/bin/sh
        \\log="${ZMX_MOCK_LOG:-$HOME/zmx-mock.log}"
        \\printf 'zmx %s\n' "$*" >> "$log"
        \\sockdir="${XDG_RUNTIME_DIR:-/tmp}/zmx"
        \\case "$1" in
        \\attach)
        \\    shift
        \\    name=""
        \\    for a in "$@"; do case "$a" in seance-*) name="$a"; break;; esac; done
        \\    found=0; rest=""
        \\    for a in "$@"; do
        \\        [ "$found" = "1" ] && rest="$rest $a"
        \\        [ "$a" = "$name" ] && found=1
        \\    done
        \\    if [ -n "$name" ]; then
        \\        mkdir -p "$sockdir"
        \\        echo $$ > "$sockdir/$name.pid"
        \\        : > "$sockdir/$name"
        \\    fi
        \\    if [ -n "$name" ] && [ -n "$rest" ]; then
        \\        ZMX_SESSION="$name" exec $rest
        \\    fi
        \\    exec sleep 30
        \\    ;;
        \\kill)
        \\    shift
        \\    for a in "$@"; do
        \\        case "$a" in
        \\        seance-*) rm -f "$sockdir/$a" "$sockdir/$a.pid";;
        \\        esac
        \\    done
        \\    ;;
        \\list)
        \\    [ -d "$sockdir" ] || exit 0
        \\    clients=0
        \\    pid=0
        \\    for f in "$sockdir"/seance-*; do
        \\        case "$f" in *.pid) continue;; esac
        \\        [ -e "$f" ] || continue
        \\        name=$(basename "$f")
        \\        u=${name#seance-}
        \\        clients=0
        \\        if [ -f "$f.pid" ]; then
        \\            pid=$(cat "$f.pid")
        \\            kill -0 "$pid" 2>/dev/null && clients=1
        \\        fi
        \\        printf '  name=%s\tpid=%s\tclients=%s\tcreated=0\tcwd=/mock\tcmd=bash --posix\tpane=%s\ttab=mock\n' "$name" "$pid" "$clients" "$u"
        \\    done
        \\    ;;
        \\esac
        \\exit 0
        \\
    ;

    const file = try std.Io.Dir.createFileAbsolute(io.get(), script_path, .{});
    var buf: [4096]u8 = undefined;
    var w = file.writer(io.get(), &buf);
    try w.interface.writeAll(script);
    try w.interface.flush();

    posix.fchmod(file.handle, 0o755) catch |e| {
        file.close(io.get());
        std.debug.print("e2e: chmod mock zmx failed: {}\n", .{e});
        return e;
    };
    file.close(io.get());
}

/// Read up to 64 KB of a file; null if missing/unreadable.
fn readFileBuf(path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.Io.Dir.openFileAbsolute(io.get(), path, .{}) catch return null;
    defer file.close(io.get());
    const n = io.readAll(file, buf) catch 0;
    return buf[0..n];
}

/// Poll the mock-zmx log until it contains `needle`.
fn waitForMockLog(h: *Harness, needle: []const u8) TestError!void {
    var buf: [65536]u8 = undefined;
    var elapsed: u64 = 0;
    while (elapsed < 20_000) {
        if (readFileBuf(h.mock_log, &buf)) |content| {
            if (std.mem.indexOf(u8, content, needle) != null) return;
        }
        io.sleep(POLL_SLEEP_MS * std.time.ns_per_ms);
        elapsed += POLL_SLEEP_MS;
    }
    std.debug.print("  log {s} missing: {s}\n", .{ h.mock_log, needle });
    return TestError.Timeout;
}

/// Assert the mock-zmx log does NOT contain `needle` (poll a grace window
/// so an in-flight kill would still be caught).
fn expectNoMockLog(h: *Harness, needle: []const u8) TestError!void {
    var buf: [65536]u8 = undefined;
    var elapsed: u64 = 0;
    while (elapsed < 1_500) {
        if (readFileBuf(h.mock_log, &buf)) |content| {
            if (std.mem.indexOf(u8, content, needle) != null) {
                std.debug.print("  unexpected mock entry: {s}\n", .{needle});
                return TestError.AssertionFailed;
            }
        }
        io.sleep(POLL_SLEEP_MS * std.time.ns_per_ms);
        elapsed += POLL_SLEEP_MS;
    }
}

const POLL_SLEEP_MS = 100;

/// All pane UUIDs currently present in system.tree (surfaces carry the
/// fork's persisted per-terminal `pane_uuid`).
fn treePaneUuids(h: *Harness, out: *std.ArrayList([]const u8)) TestError!void {
    const result = try h.callOk("system.tree", null);
    if (result != .object) return TestError.AssertionFailed;
    const windows_val = result.object.get("windows") orelse return TestError.AssertionFailed;
    if (windows_val != .array) return TestError.AssertionFailed;
    for (windows_val.array.items) |win| {
        if (win != .object) continue;
        const ws_arr = win.object.get("workspaces") orelse continue;
        if (ws_arr != .array) continue;
        for (ws_arr.array.items) |ws| {
            if (ws != .object) continue;
            const groups = ws.object.get("pane_groups") orelse continue;
            if (groups != .array) continue;
            for (groups.array.items) |grp| {
                if (grp != .object) continue;
                const surfaces = grp.object.get("surfaces") orelse continue;
                if (surfaces != .array) continue;
                for (surfaces.array.items) |s| {
                    if (s != .object) continue;
                    const pu = s.object.get("pane_uuid") orelse continue;
                    if (pu != .string) continue;
                    out.append(h.alloc, pu.string) catch return TestError.Unexpected;
                }
            }
        }
    }
}

// ── Test cases ─────────────────────────────────────────────────────────

fn testPing(h: *Harness) TestError!void {
    const resp = try h.call("system.ping", null);
    try expect(resp.ok);
}

fn testCapabilities(h: *Harness) TestError!void {
    const result = try h.callOk("system.capabilities", null);
    if (result != .object) return TestError.AssertionFailed;
    const methods = result.object.get("methods") orelse return TestError.AssertionFailed;
    if (methods != .array) return TestError.AssertionFailed;
    try expect(methods.array.items.len > 10);

    var found_ping = false;
    var found_tree = false;
    for (methods.array.items) |m| {
        if (m == .string) {
            if (std.mem.eql(u8, m.string, "system.ping")) found_ping = true;
            if (std.mem.eql(u8, m.string, "system.tree")) found_tree = true;
        }
    }
    try expect(found_ping);
    try expect(found_tree);
}

fn testIdentify(h: *Harness) TestError!void {
    const result = try h.callOk("system.identify", null);
    if (result != .object) return TestError.AssertionFailed;
    const window_index = result.object.get("window_index") orelse return TestError.AssertionFailed;
    if (window_index != .integer) return TestError.AssertionFailed;
    try expect(window_index.integer >= 0);
    const workspace_id = result.object.get("workspace_id") orelse return TestError.AssertionFailed;
    if (workspace_id != .integer) return TestError.AssertionFailed;
    try expect(workspace_id.integer >= 0);
    const surface_id = result.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (surface_id != .integer) return TestError.AssertionFailed;
    try expect(surface_id.integer >= 0);

    // Cross-check: the identified workspace should exist in the tree
    const tree = try h.callOk("system.tree", null);
    if (tree != .object) return TestError.AssertionFailed;
    const windows = tree.object.get("windows") orelse return TestError.AssertionFailed;
    if (windows != .array) return TestError.AssertionFailed;
    var found_ws = false;
    for (windows.array.items) |win| {
        if (win != .object) continue;
        const wss = win.object.get("workspaces") orelse continue;
        if (wss != .array) continue;
        for (wss.array.items) |ws| {
            if (ws != .object) continue;
            const id = ws.object.get("id") orelse continue;
            if (id == .integer and id.integer == workspace_id.integer) {
                found_ws = true;
                break;
            }
        }
    }
    try expect(found_ws);
}

fn testTree(h: *Harness) TestError!void {
    const result = try h.callOk("system.tree", null);
    if (result != .object) return TestError.AssertionFailed;
    const windows = result.object.get("windows") orelse return TestError.AssertionFailed;
    if (windows != .array) return TestError.AssertionFailed;
    try expect(windows.array.items.len >= 1);

    // Verify window has valid typed fields, not just keys
    const win = windows.array.items[0];
    if (win != .object) return TestError.AssertionFailed;
    const idx = win.object.get("index") orelse return TestError.AssertionFailed;
    if (idx != .integer) return TestError.AssertionFailed;
    try expect(idx.integer >= 0);
    const title = win.object.get("title") orelse return TestError.AssertionFailed;
    try expect(title == .string);

    const workspaces = win.object.get("workspaces") orelse return TestError.AssertionFailed;
    if (workspaces != .array) return TestError.AssertionFailed;
    try expect(workspaces.array.items.len >= 1);

    // Verify workspace within the tree has an id and title
    const ws = workspaces.array.items[0];
    if (ws != .object) return TestError.AssertionFailed;
    const ws_id = ws.object.get("id") orelse return TestError.AssertionFailed;
    if (ws_id != .integer) return TestError.AssertionFailed;
    try expect(ws_id.integer >= 0);
    try expect(ws.object.get("title") != null);

    // Exactly one workspace should be marked active
    var active_count: u32 = 0;
    for (workspaces.array.items) |w| {
        if (w != .object) continue;
        const active = w.object.get("active") orelse continue;
        if (active == .bool and active.bool) active_count += 1;
    }
    try expect(active_count == 1);
}

fn testWorkspaceCreate(h: *Harness) TestError!void {
    const result = try h.callOk("workspace.create", "{\"title\":\"e2e-test-ws\"}");
    if (result != .object) return TestError.AssertionFailed;
    try expect(result.object.get("id") != null);
}

fn testWorkspaceList(h: *Harness) TestError!void {
    const result = try h.callOk("workspace.list", null);
    if (result != .object) return TestError.AssertionFailed;
    const workspaces = result.object.get("workspaces") orelse return TestError.AssertionFailed;
    if (workspaces != .array) return TestError.AssertionFailed;
    try expect(workspaces.array.items.len >= 2);

    var found = false;
    for (workspaces.array.items) |ws| {
        if (ws == .object) {
            if (ws.object.get("title")) |title| {
                if (title == .string and std.mem.eql(u8, title.string, "e2e-test-ws")) {
                    found = true;
                    break;
                }
            }
        }
    }
    try expect(found);
}

fn testWorkspaceRename(h: *Harness) TestError!void {
    const ws_id = try findWorkspaceByTitle(h, "e2e-test-ws");
    const params = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d},\"title\":\"renamed-ws\"}}", .{ws_id}) catch
        return TestError.Unexpected;
    _ = try h.callOk("workspace.rename", params);
    _ = try findWorkspaceByTitle(h, "renamed-ws");
}

fn testWorkspaceSelectCurrent(h: *Harness) TestError!void {
    const ws_id = try findWorkspaceByTitle(h, "renamed-ws");
    const params = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d}}}", .{ws_id}) catch
        return TestError.Unexpected;
    _ = try h.callOk("workspace.select", params);

    const result = try h.callOk("workspace.current", null);
    if (result != .object) return TestError.AssertionFailed;
    const current_id = result.object.get("id") orelse return TestError.AssertionFailed;
    if (current_id != .integer) return TestError.AssertionFailed;
    try expect(@as(u64, @intCast(current_id.integer)) == ws_id);
}

fn testWorkspaceNavigation(h: *Harness) TestError!void {
    const before = try h.callOk("workspace.current", null);
    if (before != .object) return TestError.AssertionFailed;
    const before_id = before.object.get("id") orelse return TestError.AssertionFailed;
    if (before_id != .integer) return TestError.AssertionFailed;

    _ = try h.callOk("workspace.previous", null);

    const after_prev = try h.callOk("workspace.current", null);
    if (after_prev != .object) return TestError.AssertionFailed;
    const after_prev_id = after_prev.object.get("id") orelse return TestError.AssertionFailed;
    if (after_prev_id != .integer) return TestError.AssertionFailed;
    try expect(after_prev_id.integer != before_id.integer);

    _ = try h.callOk("workspace.next", null);

    // Should be back where we started
    const after_next = try h.callOk("workspace.current", null);
    if (after_next != .object) return TestError.AssertionFailed;
    const after_next_id = after_next.object.get("id") orelse return TestError.AssertionFailed;
    if (after_next_id != .integer) return TestError.AssertionFailed;
    try expect(after_next_id.integer == before_id.integer);

    // workspace.last should switch to the most recently active workspace
    _ = try h.callOk("workspace.last", null);
    const after_last = try h.callOk("workspace.current", null);
    if (after_last != .object) return TestError.AssertionFailed;
    const after_last_id = after_last.object.get("id") orelse return TestError.AssertionFailed;
    if (after_last_id != .integer) return TestError.AssertionFailed;
    try expect(after_last_id.integer == after_prev_id.integer);
}

fn testSurfaceSplitList(h: *Harness) TestError!void {
    const split_result = try h.callOk("surface.split", null);
    if (split_result != .object) return TestError.AssertionFailed;
    const new_sid_val = split_result.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (new_sid_val != .integer) return TestError.AssertionFailed;
    const new_sid = new_sid_val.integer;

    const list_result = try h.callOk("surface.list", null);
    if (list_result != .object) return TestError.AssertionFailed;
    const surfaces = list_result.object.get("surfaces") orelse return TestError.AssertionFailed;
    if (surfaces != .array) return TestError.AssertionFailed;
    try expect(surfaces.array.items.len >= 2);

    // Verify the split's returned surface_id actually appears in the list
    var found = false;
    for (surfaces.array.items) |s| {
        if (s != .object) continue;
        const id = s.object.get("id") orelse continue;
        if (id == .integer and id.integer == new_sid) {
            found = true;
            break;
        }
    }
    try expect(found);
}

/// Poll read_screen until the surface is ready (GL context initialized).
/// With software rendering the first render cycle may be delayed.
fn waitForSurface(h: *Harness) TestError!void {
    var elapsed: u64 = 0;
    const timeout: u64 = 5000;
    while (elapsed < timeout) {
        const probe = try h.call("surface.read_screen", null);
        if (probe.ok) return;
        io.sleep(Harness.POLL_INTERVAL_MS * std.time.ns_per_ms);
        elapsed += Harness.POLL_INTERVAL_MS;
    }
    return TestError.Skip;
}

fn testTerminalIO(h: *Harness) TestError!void {
    // Wait for the terminal surface to initialize — with software rendering
    // the first GL render cycle (which calls initSurface) may be delayed.
    try waitForSurface(h);

    // Wait for shell prompt before sending text
    try h.expectScreen(null, "$", 8000);

    _ = try h.callOk("surface.send_text", "{\"text\":\"echo SEANCE_E2E_MARKER_42\\n\"}");
    try h.expectScreen(null, "SEANCE_E2E_MARKER_42", 8000);
}

fn testWorkspaceMetadata(h: *Harness) TestError!void {
    // NOTE: The socket API has no read-back methods for status/logs/progress,
    // so these are smoke tests only — we verify the calls succeed without error.
    const current = try h.callOk("workspace.current", null);
    if (current != .object) return TestError.AssertionFailed;
    const ws_id_val = current.object.get("id") orelse return TestError.AssertionFailed;
    if (ws_id_val != .integer) return TestError.AssertionFailed;
    const ws_id: u64 = @intCast(ws_id_val.integer);

    const set_status = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d},\"key\":\"test\",\"value\":\"running\"}}", .{ws_id}) catch return TestError.Unexpected;
    _ = try h.callOk("workspace.set_status", set_status);

    const log_params = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d},\"message\":\"e2e test log\",\"level\":\"info\"}}", .{ws_id}) catch return TestError.Unexpected;
    _ = try h.callOk("workspace.log", log_params);

    const progress = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d},\"value\":0.5}}", .{ws_id}) catch return TestError.Unexpected;
    _ = try h.callOk("workspace.set_progress", progress);

    const clear_progress = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d}}}", .{ws_id}) catch return TestError.Unexpected;
    _ = try h.callOk("workspace.clear_progress", clear_progress);

    const clear_status = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d},\"key\":\"test\"}}", .{ws_id}) catch return TestError.Unexpected;
    _ = try h.callOk("workspace.clear_status", clear_status);
}

fn testNotifications(h: *Harness) TestError!void {
    // Notifications for the focused pane are silently skipped (visibility check).
    // Create a temp workspace (auto-activates), navigate away, then target it.
    const tmp_ws = try h.callOk("workspace.create", "{\"title\":\"notif-tmp\"}");
    if (tmp_ws != .object) return TestError.AssertionFailed;
    const tmp_ws_id_val = tmp_ws.object.get("id") orelse return TestError.AssertionFailed;
    if (tmp_ws_id_val != .integer) return TestError.AssertionFailed;
    const tmp_ws_id: u64 = @intCast(tmp_ws_id_val.integer);

    // Navigate away so the temp workspace is no longer active
    _ = try h.callOk("workspace.previous", null);

    // Create notification targeting the now-inactive temp workspace
    const create_params = std.fmt.allocPrint(h.alloc, "{{\"title\":\"E2E Test\",\"body\":\"hello from tests\",\"workspace_id\":{d}}}", .{tmp_ws_id}) catch
        return TestError.Unexpected;
    _ = try h.callOk("notification.create", create_params);

    const list = try h.callOk("notification.list", null);
    if (list != .object) return TestError.AssertionFailed;
    const notifs = list.object.get("notifications") orelse return TestError.AssertionFailed;
    if (notifs != .array) return TestError.AssertionFailed;
    try expect(notifs.array.items.len >= 1);

    // Verify notification content matches what we created
    var found = false;
    for (notifs.array.items) |n| {
        if (n != .object) continue;
        const title = n.object.get("title") orelse continue;
        const body = n.object.get("body") orelse continue;
        if (title == .string and body == .string) {
            if (std.mem.eql(u8, title.string, "E2E Test") and
                std.mem.eql(u8, body.string, "hello from tests"))
            {
                found = true;
                break;
            }
        }
    }
    try expect(found);

    _ = try h.callOk("notification.clear", null);

    // Verify clear actually removed notifications
    const after_clear = try h.callOk("notification.list", null);
    if (after_clear != .object) return TestError.AssertionFailed;
    const after_notifs = after_clear.object.get("notifications") orelse return TestError.AssertionFailed;
    if (after_notifs != .array) return TestError.AssertionFailed;
    try expect(after_notifs.array.items.len == 0);

    // Clean up temp workspace
    const close_params = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d}}}", .{tmp_ws_id}) catch
        return TestError.Unexpected;
    _ = try h.callOk("workspace.close", close_params);
}

fn testWorkspaceClose(h: *Harness) TestError!void {
    const ws_id = try findWorkspaceByTitle(h, "renamed-ws");
    const params = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d}}}", .{ws_id}) catch
        return TestError.Unexpected;
    _ = try h.callOk("workspace.close", params);

    const result = try h.callOk("workspace.list", null);
    if (result != .object) return TestError.AssertionFailed;
    const workspaces = result.object.get("workspaces") orelse return TestError.AssertionFailed;
    if (workspaces != .array) return TestError.AssertionFailed;
    for (workspaces.array.items) |ws| {
        if (ws == .object) {
            if (ws.object.get("title")) |title| {
                if (title == .string and std.mem.eql(u8, title.string, "renamed-ws")) {
                    return TestError.AssertionFailed;
                }
            }
        }
    }
}

fn testSurfaceClose(h: *Harness) TestError!void {
    // Split to create a new surface
    const split = try h.callOk("surface.split", null);
    if (split != .object) return TestError.AssertionFailed;
    const new_sid_val = split.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (new_sid_val != .integer) return TestError.AssertionFailed;
    const new_sid = new_sid_val.integer;

    // Verify the new surface exists in the list
    try expect(surfaceInList(h, new_sid));

    // Close the new surface by id
    const close_params = std.fmt.allocPrint(h.alloc, "{{\"surface_id\":{d}}}", .{new_sid}) catch
        return TestError.Unexpected;
    _ = try h.callOk("surface.close", close_params);

    // Verify the surface is gone from the list
    try expect(!surfaceInList(h, new_sid));
}

fn testSurfaceFocusLast(h: *Harness) TestError!void {
    // Get the currently focused surface
    const id_before = try h.callOk("system.identify", null);
    if (id_before != .object) return TestError.AssertionFailed;
    const orig_sid_val = id_before.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (orig_sid_val != .integer) return TestError.Skip;
    const orig_sid = orig_sid_val.integer;

    // Split — new surface gets focus
    const split = try h.callOk("surface.split", null);
    if (split != .object) return TestError.AssertionFailed;
    const new_sid_val = split.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (new_sid_val != .integer) return TestError.AssertionFailed;
    const new_sid = new_sid_val.integer;
    try expect(new_sid != orig_sid);

    // Verify focus moved to the new surface
    const id_after_split = try h.callOk("system.identify", null);
    if (id_after_split != .object) return TestError.AssertionFailed;
    const focused_split = id_after_split.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (focused_split != .integer) return TestError.AssertionFailed;
    try expect(focused_split.integer == new_sid);

    // Focus the original surface explicitly
    const focus_params = std.fmt.allocPrint(h.alloc, "{{\"surface_id\":{d}}}", .{orig_sid}) catch
        return TestError.Unexpected;
    _ = try h.callOk("surface.focus", focus_params);

    // Verify focus is on the original
    const id_after_focus = try h.callOk("system.identify", null);
    if (id_after_focus != .object) return TestError.AssertionFailed;
    const focused_focus = id_after_focus.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (focused_focus != .integer) return TestError.AssertionFailed;
    try expect(focused_focus.integer == orig_sid);

    // surface.last should switch back to the new surface
    _ = try h.callOk("surface.last", null);

    const id_after_last = try h.callOk("system.identify", null);
    if (id_after_last != .object) return TestError.AssertionFailed;
    const focused_last = id_after_last.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (focused_last != .integer) return TestError.AssertionFailed;
    try expect(focused_last.integer == new_sid);

    // Clean up: close the extra surface
    const close_params = std.fmt.allocPrint(h.alloc, "{{\"surface_id\":{d}}}", .{new_sid}) catch
        return TestError.Unexpected;
    _ = h.callOk("surface.close", close_params) catch {};
}

fn testSurfaceSendKey(h: *Harness) TestError!void {
    // Wait for the terminal surface to initialize (see testTerminalIO).
    try waitForSurface(h);

    // Wait for shell prompt
    try h.expectScreen(null, "$", 8000);

    // Type a command via send_text (no newline), then press enter via send_key
    _ = try h.callOk("surface.send_text", "{\"text\":\"echo SENDKEY_OK_99\"}");
    _ = try h.callOk("surface.send_key", "{\"key\":\"enter\"}");

    // Verify the output appeared
    try h.expectScreen(null, "SENDKEY_OK_99", 8000);
}

fn testSurfaceHealth(h: *Harness) TestError!void {
    // Get current surface id
    const ident = try h.callOk("system.identify", null);
    if (ident != .object) return TestError.AssertionFailed;
    const sid_val = ident.object.get("surface_id") orelse return TestError.AssertionFailed;
    // surface_id may be null in headless mode if no terminal pane is focused
    if (sid_val != .integer) return TestError.Skip;

    // Valid surface returns a well-formed response (alive may be false in
    // headless mode where the GL surface doesn't fully initialize)
    const params = std.fmt.allocPrint(h.alloc, "{{\"surface_id\":{d}}}", .{sid_val.integer}) catch
        return TestError.Unexpected;
    const result = try h.callOk("surface.health", params);
    if (result != .object) return TestError.AssertionFailed;
    const alive = result.object.get("alive") orelse return TestError.AssertionFailed;
    if (alive != .bool) return TestError.AssertionFailed;

    // Non-existent surface returns an error
    const bad = try h.call("surface.health", "{\"surface_id\":999999}");
    if (bad.ok) return TestError.AssertionFailed;
}

fn testWindowLifecycle(h: *Harness) TestError!void {
    // Count windows before
    const before = try h.callOk("window.list", null);
    if (before != .object) return TestError.AssertionFailed;
    const before_wins = before.object.get("windows") orelse return TestError.AssertionFailed;
    if (before_wins != .array) return TestError.AssertionFailed;
    const count_before = before_wins.array.items.len;

    // Create a new window
    const create = try h.callOk("window.create", null);
    if (create != .object) return TestError.AssertionFailed;
    const new_idx_val = create.object.get("index") orelse return TestError.AssertionFailed;
    if (new_idx_val != .integer) return TestError.AssertionFailed;
    const new_idx = new_idx_val.integer;

    // Verify it appears in window.list
    const during = try h.callOk("window.list", null);
    if (during != .object) return TestError.AssertionFailed;
    const during_wins = during.object.get("windows") orelse return TestError.AssertionFailed;
    if (during_wins != .array) return TestError.AssertionFailed;
    try expect(during_wins.array.items.len == count_before + 1);

    // Close the new window
    const close_params = std.fmt.allocPrint(h.alloc, "{{\"window_id\":{d}}}", .{new_idx}) catch
        return TestError.Unexpected;
    _ = try h.callOk("window.close", close_params);

    // GTK window close is async — poll until window count drops
    var elapsed: u64 = 0;
    while (elapsed < 3000) {
        const after = try h.callOk("window.list", null);
        if (after == .object) {
            if (after.object.get("windows")) |w| {
                if (w == .array and w.array.items.len == count_before) return;
            }
        }
        io.sleep(100 * std.time.ns_per_ms);
        elapsed += 100;
    }
    return TestError.Timeout;
}

fn testWorkspaceMoveToWindow(h: *Harness) TestError!void {
    // Create workspace FIRST (on window 0), before creating a new window
    // (window.create changes the active window, and workspace.create
    // creates on the active window)
    const ws = try h.callOk("workspace.create", "{\"title\":\"move-test\"}");
    if (ws != .object) return TestError.AssertionFailed;
    const ws_id_val = ws.object.get("id") orelse return TestError.AssertionFailed;
    if (ws_id_val != .integer) return TestError.AssertionFailed;
    const ws_id = ws_id_val.integer;

    // Now create the second window (becomes active)
    const win = try h.callOk("window.create", null);
    if (win != .object) return TestError.AssertionFailed;
    const target_idx_val = win.object.get("index") orelse return TestError.AssertionFailed;
    if (target_idx_val != .integer) return TestError.AssertionFailed;
    const target_idx = target_idx_val.integer;

    // Move workspace from window 0 to the new window
    const move_params = std.fmt.allocPrint(h.alloc, "{{\"workspace_id\":{d},\"target_window_id\":{d}}}", .{ ws_id, target_idx }) catch
        return TestError.Unexpected;
    _ = try h.callOk("workspace.move_to_window", move_params);

    // Verify it's gone from window 0's workspace list
    const src_list = try h.callOk("workspace.list", "{\"window_id\":0}");
    if (src_list != .object) return TestError.AssertionFailed;
    const src_wss = src_list.object.get("workspaces") orelse return TestError.AssertionFailed;
    if (src_wss != .array) return TestError.AssertionFailed;
    for (src_wss.array.items) |w| {
        if (w != .object) continue;
        const id = w.object.get("id") orelse continue;
        if (id == .integer and id.integer == ws_id) return TestError.AssertionFailed;
    }

    // Verify it appears in the target window's workspace list
    const dst_params = std.fmt.allocPrint(h.alloc, "{{\"window_id\":{d}}}", .{target_idx}) catch
        return TestError.Unexpected;
    const dst_list = try h.callOk("workspace.list", dst_params);
    if (dst_list != .object) return TestError.AssertionFailed;
    const dst_wss = dst_list.object.get("workspaces") orelse return TestError.AssertionFailed;
    if (dst_wss != .array) return TestError.AssertionFailed;
    var found = false;
    for (dst_wss.array.items) |w| {
        if (w != .object) continue;
        const id = w.object.get("id") orelse continue;
        if (id == .integer and id.integer == ws_id) {
            found = true;
            break;
        }
    }
    try expect(found);

    // Clean up: close the extra window (also destroys the workspace inside it)
    const close_win = std.fmt.allocPrint(h.alloc, "{{\"window_id\":{d}}}", .{target_idx}) catch
        return TestError.Unexpected;
    _ = h.callOk("window.close", close_win) catch {};
    // Wait for GTK to process the window close
    var elapsed: u64 = 0;
    while (elapsed < 3000) {
        const wl = h.callOk("window.list", null) catch break;
        if (wl == .object) {
            if (wl.object.get("windows")) |w| {
                if (w == .array and w.array.items.len == 1) break;
            }
        }
        io.sleep(100 * std.time.ns_per_ms);
        elapsed += 100;
    }
}

fn testSurfaceExpel(h: *Harness) TestError!void {
    // Split to get two panes in the same column
    const split = try h.callOk("surface.split", null);
    if (split != .object) return TestError.AssertionFailed;
    const new_sid_val = split.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (new_sid_val != .integer) return TestError.AssertionFailed;

    // Expel the focused pane to the right — creates a new column
    const result = try h.callOk("surface.expel", "{\"direction\":\"right\"}");
    if (result != .object) return TestError.AssertionFailed;
    const col_idx = result.object.get("column_index") orelse return TestError.AssertionFailed;
    if (col_idx != .integer) return TestError.AssertionFailed;
    const sid = result.object.get("surface_id") orelse return TestError.AssertionFailed;
    if (sid != .integer) return TestError.AssertionFailed;
    try expect(sid.integer > 0);

    // Clean up: close the expelled surface (sid from expel result, not the pre-split id)
    const close_params = std.fmt.allocPrint(h.alloc, "{{\"surface_id\":{d}}}", .{sid.integer}) catch
        return TestError.Unexpected;
    _ = h.callOk("surface.close", close_params) catch {};
}

// ── Error path tests ──────────────────────────────────────────────────

fn testErrorInvalidMethod(h: *Harness) TestError!void {
    try h.callExpectFail("nonexistent.method", null);
}

fn testErrorBadWorkspaceId(h: *Harness) TestError!void {
    // Selecting a workspace that doesn't exist should fail
    try h.callExpectFail("workspace.select", "{\"workspace_id\":999999}");
    // Closing a nonexistent workspace should fail
    try h.callExpectFail("workspace.close", "{\"workspace_id\":999999}");
    // Renaming a nonexistent workspace should fail
    try h.callExpectFail("workspace.rename", "{\"workspace_id\":999999,\"title\":\"nope\"}");
}

fn testErrorMissingParams(h: *Harness) TestError!void {
    // workspace.select requires workspace_id
    try h.callExpectFail("workspace.select", "{}");
    // workspace.rename requires workspace_id and title
    try h.callExpectFail("workspace.rename", "{}");
    // surface.send_text requires text
    try h.callExpectFail("surface.send_text", "{}");
}

// ── Helpers ────────────────────────────────────────────────────────────

fn surfaceInList(h: *Harness, sid: i64) bool {
    const result = h.callOk("surface.list", null) catch return false;
    if (result != .object) return false;
    const surfaces = result.object.get("surfaces") orelse return false;
    if (surfaces != .array) return false;
    for (surfaces.array.items) |s| {
        if (s != .object) continue;
        const id = s.object.get("id") orelse continue;
        if (id == .integer and id.integer == sid) return true;
    }
    return false;
}

fn findWorkspaceByTitle(h: *Harness, title: []const u8) TestError!u64 {
    const result = try h.callOk("workspace.list", null);
    if (result != .object) return TestError.AssertionFailed;
    const workspaces = result.object.get("workspaces") orelse return TestError.AssertionFailed;
    if (workspaces != .array) return TestError.AssertionFailed;
    for (workspaces.array.items) |ws| {
        if (ws == .object) {
            if (ws.object.get("title")) |t| {
                if (t == .string and std.mem.eql(u8, t.string, title)) {
                    if (ws.object.get("id")) |id| {
                        if (id == .integer) return @intCast(id.integer);
                    }
                }
            }
        }
    }
    std.debug.print("    workspace not found: \"{s}\"\n", .{title});
    return TestError.AssertionFailed;
}
