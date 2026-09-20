//! Builds the waybar custom-module JSON status line. This is the ONLY
//! Gmail API call the poll interval pays for -- one GET to labels/INBOX
//! via gmail.getUnreadCount.
//!
//! The tooltip is deliberately *not* built here by parsing message JSON:
//! it's read from a small cache (`saveTooltipCache`) that the popup (M5)
//! populates when it fetches message previews anyway. If that cache
//! doesn't exist yet -- e.g. the popup has never been opened -- the
//! tooltip falls back to a generic line instead of `status` doing its own
//! extra network round trips.
//!
//! Split by testability, same pattern as gmail.zig/oauth.zig:
//! `buildStatusJson` (pure, given already-decided text/class/tooltip
//! lines) and `escapePango` are unit tested directly; `run`'s
//! orchestration (directories, credentials, network) is exercised via
//! real CLI invocation against fixtures, since mocking all of that for a
//! marginal unit-test benefit isn't worth it.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const cache = @import("cache.zig");
const config = @import("config.zig");
const gmail = @import("gmail.zig");
const http = @import("http.zig");
const oauth = @import("oauth.zig");

pub const StatusClass = enum {
    unread,
    read,
    @"error",
    unauthenticated,
};

// ---- Tooltip cache (written by the popup in M5, read here) ----

const tooltip_cache_file = "tooltip.json";
const max_tooltip_cache_size = 32 * 1024;

/// Overwrites the tooltip cache with `lines` (already-decoded plain text,
/// one message per line -- Pango escaping happens at read time in
/// `buildStatusJson`, not here, so the cache stays reusable by anything
/// else that wants the plain text).
pub fn saveTooltipCache(gpa: Allocator, io: Io, dir: Dir, lines: []const []const u8) !void {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(.{ .lines = lines }, .{}, &out.writer);
    try cache.atomicWrite(dir, io, tooltip_cache_file, out.written(), cache.private_file_permissions);
}

fn freeTooltipLines(gpa: Allocator, lines: [][]u8) void {
    for (lines) |l| gpa.free(l);
    gpa.free(lines);
}

/// Returns null if there's no cache yet or it's unreadable/malformed --
/// both are normal, expected states (not errors), so the caller falls
/// back to a generic tooltip rather than failing `status` entirely.
fn loadTooltipLines(gpa: Allocator, io: Io, dir: Dir) ?[][]u8 {
    var buf: [max_tooltip_cache_size + 1]u8 = undefined;
    const data = cache.readBounded(dir, io, tooltip_cache_file, &buf) catch return null;

    const Shape = struct { lines: []const []const u8 = &.{} };
    const parsed = std.json.parseFromSlice(Shape, gpa, data, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    var out = gpa.alloc([]u8, parsed.value.lines.len) catch return null;
    var filled: usize = 0;
    for (parsed.value.lines) |line| {
        out[filled] = gpa.dupe(u8, line) catch {
            freeTooltipLines(gpa, out[0..filled]);
            return null;
        };
        filled += 1;
    }
    return out;
}

// ---- JSON status line ----

/// Escapes text for use inside a Pango-markup tooltip: waybar renders
/// `tooltip-format`/custom-module tooltips as Pango markup, and a literal
/// `<`/`&` in a sender's display name or a "Marketing <noreply@...>"-style
/// From header is otherwise misinterpreted as markup.
pub fn escapePango(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(gpa, "&amp;"),
            '<' => try out.appendSlice(gpa, "&lt;"),
            '>' => try out.appendSlice(gpa, "&gt;"),
            else => try out.append(gpa, c),
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Writes the full waybar custom-module JSON line: `{"text","alt",
/// "tooltip","class"}`. `text` is the module's visible label (typically
/// the unread count, or "" to self-hide per `hide-empty-text`); `class`
/// drives waybar CSS (`#custom-gmail.unread` etc.); `tooltip_lines` are
/// joined with newlines and Pango-escaped.
pub fn buildStatusJson(
    gpa: Allocator,
    writer: *Io.Writer,
    text: []const u8,
    class: StatusClass,
    tooltip_lines: []const []const u8,
) !void {
    var tooltip: std.ArrayList(u8) = .empty;
    defer tooltip.deinit(gpa);
    for (tooltip_lines, 0..) |line, i| {
        if (i != 0) try tooltip.append(gpa, '\n');
        const escaped = try escapePango(gpa, line);
        defer gpa.free(escaped);
        try tooltip.appendSlice(gpa, escaped);
    }

    const class_str = @tagName(class);
    try std.json.Stringify.value(.{
        .text = text,
        .alt = class_str,
        .tooltip = tooltip.items,
        .class = class_str,
    }, .{}, writer);
}

fn genericTooltip(buf: []u8, class: StatusClass, count: u32) []const u8 {
    return switch (class) {
        .read => "Inbox zero",
        .unread => std.fmt.bufPrint(buf, "{d} unread message{s}", .{ count, if (count == 1) "" else "s" }) catch "unread messages",
        .unauthenticated => "Not signed in -- run: waybar-gmail auth",
        .@"error" => "Couldn't reach Gmail",
    };
}

// ---- Orchestration (not unit-tested; see real fixture-mode CLI runs) ----

pub fn run(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buf);
    const w = &stdout_writer.interface;

    var dirs = config.openDirs(gpa, io, init.environ_map) catch |err| {
        emitFallback(w, .@"error", "Couldn't set up config/state directories");
        std.debug.print("waybar-gmail status: directory setup failed: {t}\n", .{err});
        return 0;
    };
    defer dirs.deinit(gpa, io);

    var creds = oauth.loadClientCredentials(gpa, io, dirs.config_dir, "client_secret.json") catch {
        emitFallback(w, .unauthenticated, "Not set up -- see README (client_secret.json missing)");
        return 0;
    };
    defer creds.deinit(gpa);

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    const access_token = oauth.getValidAccessToken(gpa, io, &http_client, creds, dirs.state_dir) catch |err| {
        switch (err) {
            error.NotAuthenticated => emitFallback(w, .unauthenticated, "Not signed in -- run: waybar-gmail auth"),
            else => {
                emitFallback(w, .@"error", "Couldn't refresh access token");
                std.debug.print("waybar-gmail status: token refresh failed: {t}\n", .{err});
            },
        }
        return 0;
    };
    defer gpa.free(access_token);

    var gmail_client = http.Client.initFromEnv(gpa, io, init.environ_map);
    defer gmail_client.deinit();

    const count = gmail.getUnreadCount(gpa, &gmail_client, access_token) catch |err| {
        switch (err) {
            error.Unauthorized => emitFallback(w, .unauthenticated, "Not signed in -- run: waybar-gmail auth"),
            else => {
                emitFallback(w, .@"error", "Couldn't reach Gmail");
                std.debug.print("waybar-gmail status: getUnreadCount failed: {t}\n", .{err});
            },
        }
        return 0;
    };

    const class: StatusClass = if (count == 0) .read else .unread;
    var text_buf: [16]u8 = undefined;
    const text = if (count == 0) "" else std.fmt.bufPrint(&text_buf, "{d}", .{count}) catch "";

    // A cached tooltip only makes sense while there's still unread mail --
    // at zero unread there is nothing left for it to be describing, so a
    // stale cache from before the inbox was cleared (read elsewhere, e.g.
    // on a phone) must not be shown as if it were still current.
    const cached_lines = if (count > 0) loadTooltipLines(gpa, io, dirs.state_dir) else null;
    defer if (cached_lines) |lines| freeTooltipLines(gpa, lines);

    var fallback_buf: [64]u8 = undefined;
    const tooltip_lines: []const []const u8 = if (cached_lines) |lines|
        lines
    else
        &.{genericTooltip(&fallback_buf, class, count)};

    buildStatusJson(gpa, w, text, class, tooltip_lines) catch |err| {
        std.debug.print("waybar-gmail status: failed to build status JSON: {t}\n", .{err});
        emitFallback(w, .@"error", "Internal error building status");
        return 0;
    };
    w.flush() catch {};
    return 0;
}

/// Emits a minimal, always-valid status line. Used for every failure path
/// in `run`: waybar must never see malformed JSON or a blank stdout, no
/// matter what went wrong.
fn emitFallback(w: *Io.Writer, class: StatusClass, message: []const u8) void {
    const class_str = @tagName(class);
    std.json.Stringify.value(.{
        .text = "",
        .alt = class_str,
        .tooltip = message,
        .class = class_str,
    }, .{}, w) catch return;
    w.flush() catch {};
}

// ---- tests ----

const testing = std.testing;

fn renderToString(gpa: Allocator, text: []const u8, class: StatusClass, lines: []const []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try buildStatusJson(gpa, &out.writer, text, class, lines);
    return gpa.dupe(u8, out.written());
}

test "buildStatusJson renders unread count and class" {
    const got = try renderToString(testing.allocator, "3", .unread, &.{});
    defer testing.allocator.free(got);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, got, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("3", parsed.value.object.get("text").?.string);
    try testing.expectEqualStrings("unread", parsed.value.object.get("class").?.string);
}

test "buildStatusJson with empty text (zero unread) still produces valid JSON" {
    const got = try renderToString(testing.allocator, "", .read, &.{});
    defer testing.allocator.free(got);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, got, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("", parsed.value.object.get("text").?.string);
    try testing.expectEqualStrings("read", parsed.value.object.get("class").?.string);
}

test "buildStatusJson joins multiple tooltip lines with newlines" {
    const got = try renderToString(testing.allocator, "2", .unread, &.{ "GitHub — PR merged", "Stripe — Invoice ready" });
    defer testing.allocator.free(got);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, got, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("GitHub — PR merged\nStripe — Invoice ready", parsed.value.object.get("tooltip").?.string);
}

test "buildStatusJson escapes Pango-special characters in tooltip lines" {
    const got = try renderToString(testing.allocator, "1", .unread, &.{"Marketing <promo@example.com> & Friends"});
    defer testing.allocator.free(got);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, got, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "Marketing &lt;promo@example.com&gt; &amp; Friends",
        parsed.value.object.get("tooltip").?.string,
    );
}

test "escapePango leaves ordinary text untouched" {
    const got = try escapePango(testing.allocator, "Hello, World!");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Hello, World!", got);
}

test "escapePango escapes all three special characters" {
    const got = try escapePango(testing.allocator, "<a & b>");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("&lt;a &amp; b&gt;", got);
}

test "saveTooltipCache then loadTooltipLines round-trips" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try saveTooltipCache(testing.allocator, testing.io, tmp.dir, &.{ "line one", "line two" });

    const lines = loadTooltipLines(testing.allocator, testing.io, tmp.dir).?;
    defer freeTooltipLines(testing.allocator, lines);

    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("line one", lines[0]);
    try testing.expectEqualStrings("line two", lines[1]);
}

test "loadTooltipLines returns null when no cache exists yet" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expect(loadTooltipLines(testing.allocator, testing.io, tmp.dir) == null);
}

test "loadTooltipLines returns null on malformed cache content" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = tooltip_cache_file, .data = "not json" });
    try testing.expect(loadTooltipLines(testing.allocator, testing.io, tmp.dir) == null);
}

test "genericTooltip differs sensibly by class" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Inbox zero", genericTooltip(&buf, .read, 0));
    try testing.expectEqualStrings("1 unread message", genericTooltip(&buf, .unread, 1));
    try testing.expectEqualStrings("5 unread messages", genericTooltip(&buf, .unread, 5));
    try testing.expect(std.mem.indexOf(u8, genericTooltip(&buf, .unauthenticated, 0), "auth") != null);
}
