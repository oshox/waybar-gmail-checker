//! Single/double-click dispatcher -- what waybar's `on-click` calls.
//! Waybar's custom module has no double-click concept of its own (only
//! on-click/on-click-middle/on-click-right/on-scroll-*; see
//! docs/zig-016-api-notes.md's sibling plan notes), so this process
//! detects it itself by timing consecutive invocations against a small
//! state file.
//!
//! Rather than waiting ~300ms after every single click to see if a second
//! one arrives (which would make every ordinary click feel sluggish), this
//! acts optimistically: the popup opens immediately on the first click,
//! and a fast second click replaces it with the inbox instead. A click
//! while the popup is already open (outside the double-click window)
//! toggles it closed, matching how a bar applet is expected to behave.
//!
//! The whole read-decide-act-write sequence is done under an exclusive
//! file lock, since waybar can dispatch two rapid clicks as two
//! concurrently-running `click` invocations.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const cache = @import("cache.zig");
const config = @import("config.zig");
const oauth = @import("oauth.zig");

pub const inbox_url = "https://mail.google.com/mail/u/0/#inbox";

pub const State = struct {
    last_click_ms: i64 = 0,
    popup_pid: ?i32 = null,
};

const state_file = "click.state";
const lock_file = "click.lock";
const popup_log_file = "popup.log";
const max_state_file_size = 128;

fn loadState(gpa: Allocator, io: Io, dir: Dir) State {
    var buf: [max_state_file_size + 1]u8 = undefined;
    const data = cache.readBounded(dir, io, state_file, &buf) catch return .{};
    const parsed = std.json.parseFromSlice(State, gpa, data, .{}) catch return .{};
    defer parsed.deinit();
    return parsed.value;
}

fn saveState(gpa: Allocator, io: Io, dir: Dir, state: State) !void {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(state, .{}, &out.writer);
    try cache.atomicWrite(dir, io, state_file, out.written(), cache.private_file_permissions);
}

/// Signal 0 sends nothing; the kernel still validates that `pid` refers to
/// an existing process, which is the standard way to check liveness
/// without actually signaling. `PermissionDenied` means the process exists
/// but we can't signal it (shouldn't happen for our own popup child, but
/// "exists" is still the correct answer if it somehow did).
pub fn isProcessAlive(pid: i32) bool {
    std.posix.kill(pid, @enumFromInt(0)) catch |err| switch (err) {
        error.ProcessNotFound => return false,
        error.PermissionDenied => return true,
        error.Unexpected => return false,
    };
    return true;
}

pub fn terminateProcess(pid: i32) void {
    std.posix.kill(pid, std.posix.SIG.TERM) catch {};
}

pub const Action = enum {
    spawn_popup,
    close_popup_and_open_inbox,
    close_popup,
};

/// The core decision: pure and fully unit-testable given already-known
/// facts (the previous state, the current time, and whether the
/// previously-recorded popup pid is actually still alive), separate from
/// reading those facts off the real clock/process table/lock file.
pub fn decideAction(state: State, now_ms: i64, popup_alive: bool, double_click_ms: i64) Action {
    if (now_ms - state.last_click_ms < double_click_ms) return .close_popup_and_open_inbox;
    if (popup_alive) return .close_popup;
    return .spawn_popup;
}

/// The popup used to run with stderr sent to .ignore, matching the
/// short-lived fire-and-forget subcommands elsewhere in this project.
/// That meant any panic, error print, or crash from a real click-spawned
/// popup was silently thrown away -- there was no way to tell what had
/// actually gone wrong when the popup misbehaved outside of a terminal.
/// Captured here instead (truncated fresh on every launch, so this stays
/// one small file rather than growing without bound) so a future report
/// of "it didn't open" has an actual trace to look at.
fn spawnPopup(io: Io, log_dir: Dir) !i32 {
    const stderr_target: std.process.SpawnOptions.StdIo = blk: {
        const log_file = log_dir.createFile(io, popup_log_file, .{
            .truncate = true,
            .permissions = cache.private_file_permissions,
        }) catch break :blk .ignore;
        break :blk .{ .file = log_file };
    };
    defer if (stderr_target == .file) stderr_target.file.close(io);

    const child = try std.process.spawn(io, .{
        .argv = &.{"waybar-gmail-popup"},
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = stderr_target,
    });
    return child.id.?;
}

pub fn run(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;

    var dirs = config.openDirs(gpa, io, init.environ_map) catch |err| {
        std.debug.print("waybar-gmail click: can't set up directories: {t}\n", .{err});
        return 1;
    };
    defer dirs.deinit(gpa, io);

    const cfg = config.load(gpa, io, dirs.config_dir);

    var lock = dirs.state_dir.createFile(io, lock_file, .{
        .lock = .exclusive,
        .truncate = false,
        .permissions = cache.private_file_permissions,
    }) catch |err| {
        std.debug.print("waybar-gmail click: can't acquire lock: {t}\n", .{err});
        return 1;
    };
    defer lock.close(io);

    const now_ms = Io.Timestamp.now(io, .awake).toMilliseconds();
    const state = loadState(gpa, io, dirs.state_dir);
    const popup_alive = if (state.popup_pid) |pid| isProcessAlive(pid) else false;
    const action = decideAction(state, now_ms, popup_alive, @intCast(cfg.double_click_ms));

    var next_popup_pid: ?i32 = null;
    switch (action) {
        .close_popup_and_open_inbox => {
            if (popup_alive) terminateProcess(state.popup_pid.?);
            oauth.openInBrowser(io, inbox_url) catch |err| {
                std.debug.print("waybar-gmail click: couldn't open inbox: {t}\n", .{err});
            };
        },
        .close_popup => {
            if (popup_alive) terminateProcess(state.popup_pid.?);
        },
        .spawn_popup => {
            next_popup_pid = spawnPopup(io, dirs.state_dir) catch |err| blk: {
                std.debug.print("waybar-gmail click: couldn't spawn popup: {t}\n", .{err});
                break :blk null;
            };
        },
    }

    saveState(gpa, io, dirs.state_dir, .{ .last_click_ms = now_ms, .popup_pid = next_popup_pid }) catch |err| {
        std.debug.print("waybar-gmail click: couldn't save click state: {t}\n", .{err});
    };

    return 0;
}

// ---- tests ----

const testing = std.testing;

const default_threshold_ms: i64 = 350;

test "decideAction: first-ever click with no prior state spawns the popup" {
    const action = decideAction(.{}, 1_000_000, false, default_threshold_ms);
    try testing.expectEqual(Action.spawn_popup, action);
}

test "decideAction: a second click within the threshold opens the inbox" {
    const state: State = .{ .last_click_ms = 1000, .popup_pid = 4242 };
    const action = decideAction(state, 1000 + 200, true, default_threshold_ms);
    try testing.expectEqual(Action.close_popup_and_open_inbox, action);
}

test "decideAction: a click outside the threshold with the popup already open closes it" {
    const state: State = .{ .last_click_ms = 1000, .popup_pid = 4242 };
    const action = decideAction(state, 1000 + 5000, true, default_threshold_ms);
    try testing.expectEqual(Action.close_popup, action);
}

test "decideAction: a click outside the threshold with no popup open spawns one" {
    const state: State = .{ .last_click_ms = 1000, .popup_pid = null };
    const action = decideAction(state, 1000 + 5000, false, default_threshold_ms);
    try testing.expectEqual(Action.spawn_popup, action);
}

test "decideAction: exactly at the threshold boundary is not a double-click" {
    const state: State = .{ .last_click_ms = 1000, .popup_pid = null };
    // now_ms - last_click_ms == double_click_ms is NOT < threshold, so this
    // must be treated as a fresh click, not a double-click.
    const action = decideAction(state, 1000 + default_threshold_ms, false, default_threshold_ms);
    try testing.expectEqual(Action.spawn_popup, action);
}

test "decideAction: a popup pid recorded but the process died is treated as not open" {
    // popup_alive=false here models the earlier popup having exited on its
    // own (e.g. the user pressed Escape) between clicks -- the stale pid
    // in state must not prevent a fresh popup from opening.
    const state: State = .{ .last_click_ms = 1000, .popup_pid = 4242 };
    const action = decideAction(state, 1000 + 5000, false, default_threshold_ms);
    try testing.expectEqual(Action.spawn_popup, action);
}

test "decideAction: rapid double-click takes priority even if a popup happens to be open" {
    // Not a realistic combination in practice (a popup can't usually exist
    // yet 200ms after the very first click that would have spawned it),
    // but the priority order itself -- double-click wins over "is a popup
    // open" -- must hold regardless.
    const state: State = .{ .last_click_ms = 1000, .popup_pid = 4242 };
    const action = decideAction(state, 1000 + 100, true, default_threshold_ms);
    try testing.expectEqual(Action.close_popup_and_open_inbox, action);
}

test "isProcessAlive is true for our own process" {
    const my_pid: i32 = @intCast(std.os.linux.getpid());
    try testing.expect(isProcessAlive(my_pid));
}

test "isProcessAlive is false for a pid that almost certainly doesn't exist" {
    try testing.expect(!isProcessAlive(999_999));
}

test "saveState then loadState round-trips" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try saveState(testing.allocator, testing.io, tmp.dir, .{ .last_click_ms = 123456789, .popup_pid = 4242 });

    const got = loadState(testing.allocator, testing.io, tmp.dir);
    try testing.expectEqual(@as(i64, 123456789), got.last_click_ms);
    try testing.expectEqual(@as(?i32, 4242), got.popup_pid);
}

test "loadState defaults to zero/null when no state file exists yet" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const got = loadState(testing.allocator, testing.io, tmp.dir);
    try testing.expectEqual(@as(i64, 0), got.last_click_ms);
    try testing.expectEqual(@as(?i32, null), got.popup_pid);
}

test "loadState defaults on malformed content instead of crashing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = state_file, .data = "not json" });
    const got = loadState(testing.allocator, testing.io, tmp.dir);
    try testing.expectEqual(@as(i64, 0), got.last_click_ms);
}

test "saveState with a null popup_pid round-trips correctly" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try saveState(testing.allocator, testing.io, tmp.dir, .{ .last_click_ms = 42, .popup_pid = null });
    const got = loadState(testing.allocator, testing.io, tmp.dir);
    try testing.expectEqual(@as(?i32, null), got.popup_pid);
}
