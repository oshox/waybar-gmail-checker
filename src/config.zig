//! Our own settings (~/.config/waybar-gmail/config.json) -- deliberately
//! separate from Google's client_secret.json (see oauth.zig), so the OAuth
//! credential file stays untouched and independently replaceable.
//!
//! Note what's *not* here: a poll interval. Waybar itself controls when
//! `status` runs (the `interval` field in the waybar module config), so a
//! value here would just be dead configuration nothing reads.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const cache = @import("cache.zig");

/// Pure computation of ~/.config/waybar-gmail, given $HOME. Kept separate
/// from environment access for the same reason as cache.runtimeDirPath:
/// testable without touching the real environment.
pub fn configDirPath(gpa: Allocator, home: ?[]const u8) error{ OutOfMemory, NoHome }![]u8 {
    const base = home orelse return error.NoHome;
    if (base.len == 0) return error.NoHome;
    return Dir.path.join(gpa, &.{ base, ".config", "waybar-gmail" }) catch return error.OutOfMemory;
}

/// Both of the app's directories, opened (and created if necessary):
/// config (~/.config/waybar-gmail, holds client_secret.json and
/// config.json) and state ($XDG_RUNTIME_DIR/waybar-gmail, holds the
/// access-token and tooltip caches). Every subcommand that touches disk
/// or the network starts by calling `openDirs`.
pub const Dirs = struct {
    config_dir: Dir,
    config_path: []u8,
    state_dir: Dir,
    state_path: []u8,

    pub fn deinit(self: *Dirs, gpa: Allocator, io: Io) void {
        self.config_dir.close(io);
        gpa.free(self.config_path);
        self.state_dir.close(io);
        gpa.free(self.state_path);
        self.* = undefined;
    }
};

pub fn openDirs(gpa: Allocator, io: Io, environ_map: *const std.process.Environ.Map) !Dirs {
    const config_path = try configDirPath(gpa, environ_map.get("HOME"));
    errdefer gpa.free(config_path);
    var config_dir = try cache.openOrCreateAppDir(io, config_path);
    errdefer config_dir.close(io);

    const state_path = try cache.runtimeDirPath(gpa, environ_map.get("XDG_RUNTIME_DIR"));
    errdefer gpa.free(state_path);
    const state_dir = try cache.openOrCreateAppDir(io, state_path);

    return .{ .config_dir = config_dir, .config_path = config_path, .state_dir = state_dir, .state_path = state_path };
}

/// Upper bound for `max_messages`. Gmail itself allows far more per list
/// call, but every message past the first costs a preview request the first
/// time it's seen, and the popup only shows a handful at a time anyway.
pub const max_messages_limit: u32 = 50;
pub const default_max_messages: u32 = 15;

pub const Config = struct {
    /// How many unread messages are listed and previewed (the cache the
    /// popup and the tooltip are built from). Always within
    /// 1..max_messages_limit.
    max_messages: u32 = default_max_messages,
    /// Gap between a first and second click that counts as a double-click
    /// (see click.zig, M4).
    double_click_ms: u32 = 350,
    /// Which signed-in Google account to open messages in: the N in
    /// mail.google.com/mail/u/N/. 0 is the browser's first signed-in
    /// account, which is right unless Gmail opens the wrong mailbox for you.
    account_index: u32 = 0,
    /// The popup closes itself this long after opening if the pointer never
    /// enters it (so one you opened and walked away from doesn't sit on
    /// screen forever). 0 disables.
    idle_close_ms: u32 = 5000,
};

const JsonShape = struct {
    max_messages: ?u32 = null,
    double_click_ms: ?u32 = null,
    account_index: ?u32 = null,
    idle_close_ms: ?u32 = null,
};

/// 0 is invalid (Gmail would answer a maxResults of 0 with its own default
/// of 100, i.e. 100 preview requests), so it falls back to the default;
/// anything above the limit is capped.
pub fn normalizeMaxMessages(v: u32) u32 {
    if (v == 0) return default_max_messages;
    return @min(v, max_messages_limit);
}

const max_config_file_size = 16 * 1024;

/// Loads config.json from `dir` if present. A missing file, a file too
/// large to be a sane config, or malformed/invalid JSON all fall back to
/// defaults silently -- a broken config must never stop `status` (or
/// anything else) from working; it's a convenience, not a dependency.
pub fn load(gpa: Allocator, io: Io, dir: Dir) Config {
    var buf: [max_config_file_size + 1]u8 = undefined;
    const data = cache.readBounded(dir, io, "config.json", &buf) catch return .{};

    const parsed = std.json.parseFromSlice(JsonShape, gpa, data, .{
        .ignore_unknown_fields = true,
    }) catch return .{};
    defer parsed.deinit();

    var cfg: Config = .{};
    if (parsed.value.max_messages) |v| cfg.max_messages = normalizeMaxMessages(v);
    if (parsed.value.double_click_ms) |v| cfg.double_click_ms = v;
    if (parsed.value.account_index) |v| cfg.account_index = v;
    if (parsed.value.idle_close_ms) |v| cfg.idle_close_ms = v;
    return cfg;
}

// ---- tests ----

const testing = std.testing;

test "configDirPath joins HOME with .config/waybar-gmail" {
    const got = try configDirPath(testing.allocator, "/home/oshox");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/home/oshox/.config/waybar-gmail", got);
}

test "configDirPath rejects a null HOME" {
    try testing.expectError(error.NoHome, configDirPath(testing.allocator, null));
}

test "load returns defaults when config.json is absent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const cfg = load(testing.allocator, testing.io, tmp.dir);
    try testing.expectEqual(@as(u32, 15), cfg.max_messages);
    try testing.expectEqual(@as(u32, 350), cfg.double_click_ms);
}

test "load applies overrides from a valid config.json" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config.json",
        .data = "{\"max_messages\": 5, \"double_click_ms\": 400}",
    });

    const cfg = load(testing.allocator, testing.io, tmp.dir);
    try testing.expectEqual(@as(u32, 5), cfg.max_messages);
    try testing.expectEqual(@as(u32, 400), cfg.double_click_ms);
}

test "load applies partial overrides, defaulting the rest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config.json",
        .data = "{\"max_messages\": 20}",
    });

    const cfg = load(testing.allocator, testing.io, tmp.dir);
    try testing.expectEqual(@as(u32, 20), cfg.max_messages);
    try testing.expectEqual(@as(u32, 350), cfg.double_click_ms);
}

test "load falls back to defaults on malformed JSON" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config.json",
        .data = "{not valid json at all",
    });

    const cfg = load(testing.allocator, testing.io, tmp.dir);
    try testing.expectEqual(@as(u32, 15), cfg.max_messages);
    try testing.expectEqual(@as(u32, 350), cfg.double_click_ms);
}

test "normalizeMaxMessages: 0 falls back to the default, huge values are capped" {
    try testing.expectEqual(@as(u32, 15), normalizeMaxMessages(0));
    try testing.expectEqual(@as(u32, 1), normalizeMaxMessages(1));
    try testing.expectEqual(@as(u32, 50), normalizeMaxMessages(50));
    try testing.expectEqual(@as(u32, 50), normalizeMaxMessages(51));
    try testing.expectEqual(@as(u32, 50), normalizeMaxMessages(4_000_000_000));
}

test "load clamps an out-of-range max_messages" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = "{\"max_messages\": 500}" });
    try testing.expectEqual(@as(u32, 50), load(testing.allocator, testing.io, tmp.dir).max_messages);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = "{\"max_messages\": 0}" });
    try testing.expectEqual(@as(u32, 15), load(testing.allocator, testing.io, tmp.dir).max_messages);
}

test "load reads account_index and idle_close_ms, with defaults when absent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const defaults = load(testing.allocator, testing.io, tmp.dir);
    try testing.expectEqual(@as(u32, 0), defaults.account_index);
    try testing.expectEqual(@as(u32, 5000), defaults.idle_close_ms);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "config.json", .data = "{\"account_index\": 2, \"idle_close_ms\": 0}" });
    const cfg = load(testing.allocator, testing.io, tmp.dir);
    try testing.expectEqual(@as(u32, 2), cfg.account_index);
    try testing.expectEqual(@as(u32, 0), cfg.idle_close_ms);
}

test "load ignores unknown fields instead of failing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "config.json",
        .data = "{\"max_messages\": 8, \"some_future_setting\": true}",
    });

    const cfg = load(testing.allocator, testing.io, tmp.dir);
    try testing.expectEqual(@as(u32, 8), cfg.max_messages);
}
