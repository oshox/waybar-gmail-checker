//! Builds the waybar custom-module JSON status line. Every poll starts
//! with the cheap GET to labels/INBOX via gmail.getUnreadCount; while
//! anything is unread it then also refreshes the message list and
//! previews (messages_cache.fetchFromApi) -- every poll, not only when the
//! count changed, so the popup always opens from a cache at most one poll
//! interval old. See `run` for the details.
//!
//! The tooltip is built from that same structured message cache
//! (messages_cache), which this poll's refresh or the popup (whichever
//! last ran) keeps up to date. If neither has ever run, or a refresh
//! failed, the tooltip falls back to the last cached lines or a generic
//! line rather than failing the poll.
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
const messages_cache = @import("messages_cache.zig");
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
/// else that wants the plain text) and `unread`, the inbox's real unread
/// total. The total is stored because the list itself is capped at
/// `max_messages`, so the popup can't derive it -- and reading it from here
/// means it can say "28 unread" the instant it opens, with no network call.
pub fn saveTooltipCache(gpa: Allocator, io: Io, dir: Dir, lines: []const []const u8, unread: u32) !void {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(.{ .lines = lines, .unread = unread }, .{}, &out.writer);
    try cache.atomicWrite(dir, io, tooltip_cache_file, out.written(), cache.private_file_permissions);
}

/// The unread total stored by `saveTooltipCache`, or null when there's no
/// cache, it's unreadable, or it predates this field (all normal states).
pub fn loadUnreadCount(gpa: Allocator, io: Io, dir: Dir) ?u32 {
    var buf: [max_tooltip_cache_size + 1]u8 = undefined;
    const data = cache.readBounded(dir, io, tooltip_cache_file, &buf) catch return null;
    const Shape = struct { unread: ?u32 = null };
    const parsed = std.json.parseFromSlice(Shape, gpa, data, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    return parsed.value.unread;
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

/// Escapes text for use as Pango markup. Needed both for the popup's GTK
/// labels (popup.zig, before gtk_label_set_markup) and for the waybar
/// tooltip below: confirmed live, the hard way, that waybar's
/// custom-module tooltip *does* parse its text as Pango markup here (an
/// earlier version of this comment claimed otherwise based on old GitHub
/// issues describing a different waybar version/symptom -- that was
/// wrong, and trusting it over direct verification produced a real
/// regression: unescaped "<address>" text is invalid markup, which GTK
/// fails to parse and renders as an empty tooltip rather than falling
/// back to showing it as plain text).
///
/// Also drops characters that aren't legal in XML-ish markup at all: ASCII
/// control characters other than tab and newline, DEL, and the U+FFFE /
/// U+FFFF non-characters. They can arrive in a Subject via a crafted
/// RFC 2047 word (`=?UTF-8?Q?=01?=`), and since a markup parse failure
/// blanks the entire tooltip, one hostile sender shouldn't be able to do
/// that. (Whether Pango really rejects them wasn't verifiable here; they
/// carry no meaning in a one-line preview either way.)
pub fn escapePango(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        switch (c) {
            '&' => try out.appendSlice(gpa, "&amp;"),
            '<' => try out.appendSlice(gpa, "&lt;"),
            '>' => try out.appendSlice(gpa, "&gt;"),
            '\t', '\n' => try out.append(gpa, c),
            0x00...0x08, 0x0B...0x1F, 0x7F => {},
            // U+FFFE / U+FFFF are EF BF BE / EF BF BF in UTF-8.
            0xEF => if (i + 2 < text.len and text[i + 1] == 0xBF and (text[i + 2] == 0xBE or text[i + 2] == 0xBF)) {
                try out.appendSlice(gpa, "\u{FFFD}");
                i += 2;
            } else {
                try out.append(gpa, c);
            },
            else => try out.append(gpa, c),
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Writes the full waybar custom-module JSON line: `{"text","alt",
/// "tooltip","class"}`. `text` is the module's visible label (typically
/// the unread count, or "" to self-hide per `hide-empty-text`); `class`
/// drives waybar CSS (`#custom-gmail.unread` etc.); `tooltip_lines` are
/// joined with newlines and Pango-escaped -- the tooltip is markup, and
/// unescaped "<"/"&" from a "Name <address>"-shaped From header is
/// otherwise invalid markup that fails to parse (see escapePango).
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
        .read => "No unread messages",
        .unread => std.fmt.bufPrint(buf, "{d} unread message{s}", .{ count, if (count == 1) "" else "s" }) catch "unread messages",
        .unauthenticated => "Not signed in -- run: waybar-gmail auth",
        .@"error" => "Couldn't reach Gmail",
    };
}

// ---- Watchdog: a poll that hangs must not freeze the module ----
//
// std.http.Client has no read or fetch timeout, so a connection that stalls
// (a captive portal, a dead route, a half-open socket) would block `status`
// forever -- and waybar waits for the previous run before starting the next,
// so the module would sit on stale output indefinitely. A detached thread
// sleeps for `poll_timeout_s` and, if the poll still hasn't produced output,
// writes an error line and exits the process.

/// A normal poll is one or two requests; even a first run fetching a full
/// page of previews finishes in a few seconds. This is a backstop, not a
/// budget.
const poll_timeout_s: i64 = 30;

const timeout_json =
    \\{"text":"","alt":"error","tooltip":"Gmail request timed out","class":"error"}
++ "\n";

/// Decides who gets to write the status line: the poll itself, or the
/// watchdog. Exactly one ever does, so output can't be duplicated or
/// interleaved when the two race at the timeout. The main thread may ask
/// repeatedly (it can legitimately write more than once, e.g. a fallback
/// after a failed render); once the watchdog has won, the main thread stays
/// silent and the process is already on its way out.
const OutputGate = struct {
    state: std.atomic.Value(u8) = .init(unclaimed),

    const unclaimed = 0;
    const main_owns = 1;
    const watchdog_owns = 2;

    fn claimForMain(self: *OutputGate) bool {
        const prev = self.state.cmpxchgStrong(unclaimed, main_owns, .acq_rel, .acquire);
        return prev == null or prev.? == main_owns;
    }

    fn claimForWatchdog(self: *OutputGate) bool {
        return self.state.cmpxchgStrong(unclaimed, watchdog_owns, .acq_rel, .acquire) == null;
    }
};

var output_gate: OutputGate = .{};

fn watchdog(io: Io) void {
    io.sleep(Io.Duration.fromSeconds(poll_timeout_s), .awake) catch return;
    // The poll got there first and is writing (or has written) its result:
    // leave it alone, the process exits normally when `run` returns.
    if (!output_gate.claimForWatchdog()) return;
    Io.File.stdout().writeStreamingAll(io, timeout_json) catch {};
    std.debug.print("waybar-gmail status: no response within {d}s, giving up\n", .{poll_timeout_s});
    std.process.exit(0);
}

// ---- Orchestration (not unit-tested; see real fixture-mode CLI runs) ----

pub fn run(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;

    // If this can't be started the poll just runs without a backstop.
    if (std.Thread.spawn(.{}, watchdog, .{io})) |t| t.detach() else |_| {}

    // .writerStreaming, not .writer: the latter assumes a seekable regular
    // file and issues a positional pwritev first, which (confirmed via
    // strace) fails with ESPIPE against a pipe -- which is exactly what
    // stdout is when waybar runs this -- and falls back to a second,
    // ordinary writev. That's a wasted failing syscall on every single
    // poll, 1440 times a day; writerStreaming goes straight to the
    // ordinary write path with no positional attempt.
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buf);
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
    defer oauth.secureFree(gpa, access_token);

    var gmail_client = http.Client.initFromEnv(gpa, io, init.environ_map);
    defer gmail_client.deinit();

    const count = gmail.getUnreadCount(gpa, &gmail_client, access_token) catch |err| {
        switch (err) {
            error.Unauthorized => emitFallback(w, .unauthenticated, "Not signed in -- run: waybar-gmail auth"),
            // Transient: say so rather than "Not signed in", which would
            // send the user off to re-authenticate for nothing.
            error.RateLimited => emitFallback(w, .@"error", "Gmail is rate limiting requests -- will retry next poll"),
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

    // Tooltip lines for this run: freshly fetched below if the refresh
    // succeeds, otherwise whatever's cached from the popup's or a previous
    // poll's refresh, otherwise a generic fallback. Owned by this if
    // non-null; freed once at the end either way, regardless of which
    // source it came from.
    var owned_lines: ?[][]u8 = null;
    defer if (owned_lines) |lines| freeTooltipLines(gpa, lines);

    if (count == 0) {
        // Nothing left to cache a preview of -- and a stale, nonempty
        // cache from before the inbox was cleared (read elsewhere, e.g.
        // on a phone) must not linger and be shown once count is
        // nonzero again, or painted by the popup's cache-first open.
        messages_cache.save(gpa, io, dirs.state_dir, &.{}) catch {};
        saveTooltipCache(gpa, io, dirs.state_dir, &.{}, 0) catch {};
    } else refresh: {
        // While anything is unread, refresh the list and previews on every
        // poll. This used to happen only when the unread count differed
        // from the number of cached entries, which was both too little
        // and too much: with more unread than `max_messages` the cache
        // could never match the count (so it refetched every poll anyway),
        // and one message read plus one new one left the count unchanged
        // and the previews stale. Refreshing unconditionally keeps the
        // cache the popup opens from at most one poll interval old.
        //
        // What makes that cheap: the *list* is fetched every time, but a
        // message's preview never changes, so previews already in the
        // cache are reused and only ids not seen before cost a request. A
        // poll with nothing new is the count call plus one list call.
        const cfg = config.load(gpa, io, dirs.config_dir);
        var known = messages_cache.load(gpa, io, dirs.state_dir) orelse std.ArrayList(messages_cache.Entry).empty;
        defer {
            for (known.items) |*e| e.deinit(gpa);
            known.deinit(gpa);
        }
        const entries = messages_cache.fetchFromApi(gpa, &gmail_client, access_token, cfg.max_messages, known.items) catch |err| {
            std.debug.print("waybar-gmail status: refresh failed: {t}\n", .{err});
            break :refresh;
        };
        defer messages_cache.freeEntries(gpa, entries);

        // Unread mail exists (count > 0) but not one preview came back --
        // every per-message fetch failed. Don't let that wipe a good cache
        // and blank the tooltip; keep what's there (the fallbacks below).
        if (entries.len == 0) {
            std.debug.print("waybar-gmail status: refresh returned no previews for {d} unread, keeping the cache\n", .{count});
            break :refresh;
        }

        messages_cache.save(gpa, io, dirs.state_dir, entries) catch |err| {
            std.debug.print("waybar-gmail status: couldn't save message cache: {t}\n", .{err});
        };
        const lines = messages_cache.buildTooltipLines(gpa, entries) catch |err| {
            std.debug.print("waybar-gmail status: couldn't build tooltip lines: {t}\n", .{err});
            break :refresh;
        };
        saveTooltipCache(gpa, io, dirs.state_dir, lines, count) catch |err| {
            std.debug.print("waybar-gmail status: couldn't save tooltip cache: {t}\n", .{err});
        };
        owned_lines = lines;
    }

    if (owned_lines == null and count > 0) {
        owned_lines = loadTooltipLines(gpa, io, dirs.state_dir);
    }

    var fallback_buf: [64]u8 = undefined;
    const tooltip_lines: []const []const u8 = if (owned_lines) |lines|
        lines
    else
        &.{genericTooltip(&fallback_buf, class, count)};

    // Past this point the result is ready; if the watchdog already fired
    // (the poll was too slow) it has written its own line and is exiting.
    if (!output_gate.claimForMain()) return 0;
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
    if (!output_gate.claimForMain()) return; // the watchdog already answered
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
    // Confirmed live: waybar's custom-module tooltip parses its text as
    // Pango markup. Unescaped, a "Name <address>" From header is invalid
    // markup that GTK fails to parse, rendering an empty tooltip rather
    // than falling back to plain text -- that's the regression this
    // guards against (an earlier version of this test asserted the
    // opposite, unescaped behavior, based on a wrong conclusion from old
    // GitHub issues rather than direct verification; see escapePango's
    // comment for the full story).
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

test "OutputGate: exactly one side ever wins" {
    var gate: OutputGate = .{};
    // The watchdog wins the race...
    try testing.expect(gate.claimForWatchdog());
    // ...so the poll must stay silent, however often it asks.
    try testing.expect(!gate.claimForMain());
    try testing.expect(!gate.claimForMain());
    try testing.expect(!gate.claimForWatchdog());
}

test "OutputGate: once the poll owns the output it may write repeatedly, and the watchdog never can" {
    var gate: OutputGate = .{};
    try testing.expect(gate.claimForMain());
    // e.g. a failed render followed by a fallback line.
    try testing.expect(gate.claimForMain());
    try testing.expect(!gate.claimForWatchdog());
}

test "timeout_json is one valid JSON line with the error class" {
    try testing.expect(std.mem.endsWith(u8, timeout_json, "\n"));
    try testing.expectEqual(@as(?usize, timeout_json.len - 1), std.mem.indexOfScalar(u8, timeout_json, '\n'));
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, timeout_json, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("error", parsed.value.object.get("class").?.string);
    try testing.expectEqualStrings("", parsed.value.object.get("text").?.string);
}

test "escapePango drops control characters but keeps tab, newline and ordinary text" {
    const got = try escapePango(testing.allocator, "a\x01b\x1bc\x7fd\te\nf\r");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("abcd\te\nf", got);
}

test "escapePango replaces the U+FFFE/U+FFFF non-characters and leaves other 0xEF sequences alone" {
    const got = try escapePango(testing.allocator, "a\u{FFFE}b\u{FFFF}c\u{FFFD}d€e");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}c\u{FFFD}d€e", got);
    try testing.expect(std.unicode.utf8ValidateSlice(got));
}

test "escapePango handles a truncated trailing 0xEF without reading out of bounds" {
    const got = try escapePango(testing.allocator, "ok\xEF\xBF");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("ok\xEF\xBF", got);
}

test "saveTooltipCache then loadTooltipLines round-trips" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try saveTooltipCache(testing.allocator, testing.io, tmp.dir, &.{ "line one", "line two" }, 7);

    const lines = loadTooltipLines(testing.allocator, testing.io, tmp.dir).?;
    defer freeTooltipLines(testing.allocator, lines);

    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("line one", lines[0]);
    try testing.expectEqualStrings("line two", lines[1]);

    // The unread total travels with the lines.
    try testing.expectEqual(@as(?u32, 7), loadUnreadCount(testing.allocator, testing.io, tmp.dir));
}

test "loadUnreadCount is null when there's no cache, no field, or garbage" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expectEqual(@as(?u32, null), loadUnreadCount(testing.allocator, testing.io, tmp.dir));

    // A cache written before the field existed.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = tooltip_cache_file, .data = "{\"lines\":[\"old\"]}" });
    try testing.expectEqual(@as(?u32, null), loadUnreadCount(testing.allocator, testing.io, tmp.dir));
    // ...and it still loads its lines fine.
    const lines = loadTooltipLines(testing.allocator, testing.io, tmp.dir).?;
    defer freeTooltipLines(testing.allocator, lines);
    try testing.expectEqualStrings("old", lines[0]);

    try tmp.dir.writeFile(testing.io, .{ .sub_path = tooltip_cache_file, .data = "not json" });
    try testing.expectEqual(@as(?u32, null), loadUnreadCount(testing.allocator, testing.io, tmp.dir));
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
    try testing.expectEqualStrings("No unread messages", genericTooltip(&buf, .read, 0));
    try testing.expectEqualStrings("1 unread message", genericTooltip(&buf, .unread, 1));
    try testing.expectEqualStrings("5 unread messages", genericTooltip(&buf, .unread, 5));
    try testing.expect(std.mem.indexOf(u8, genericTooltip(&buf, .unauthenticated, 0), "auth") != null);
}
