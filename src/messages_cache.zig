//! The structured per-message cache (id, thread id, sender, subject,
//! snippet) that the popup paints from immediately on open, plus the
//! network fetch that populates it. Kept separate from popup.zig, which
//! is GTK-specific and only linked into the popup binary, so status.zig
//! -- part of the GTK-free static CLI binary -- can also refresh this
//! cache from the 60s poll without pulling in anything GTK-related.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const cache = @import("cache.zig");
const gmail = @import("gmail.zig");
const http = @import("http.zig");

pub const Entry = struct {
    id: []const u8,
    thread_id: []const u8,
    from: []const u8,
    subject: []const u8,
    snippet: []const u8,

    pub fn deinit(self: *Entry, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.thread_id);
        gpa.free(self.from);
        gpa.free(self.subject);
        gpa.free(self.snippet);
        self.* = undefined;
    }
};

pub fn freeEntries(gpa: Allocator, entries: []Entry) void {
    for (entries) |*e| e.deinit(gpa);
    gpa.free(entries);
}

/// Builds an Entry that owns copies of all five strings. If any copy fails,
/// the ones already made are freed (an inline struct literal full of
/// `try gpa.dupe(...)` would leak them).
fn makeEntry(
    gpa: Allocator,
    id: []const u8,
    thread_id: []const u8,
    from: []const u8,
    subject: []const u8,
    snippet: []const u8,
) Allocator.Error!Entry {
    const id_copy = try gpa.dupe(u8, id);
    errdefer gpa.free(id_copy);
    const thread_copy = try gpa.dupe(u8, thread_id);
    errdefer gpa.free(thread_copy);
    const from_copy = try gpa.dupe(u8, from);
    errdefer gpa.free(from_copy);
    const subject_copy = try gpa.dupe(u8, subject);
    errdefer gpa.free(subject_copy);
    const snippet_copy = try gpa.dupe(u8, snippet);
    return .{
        .id = id_copy,
        .thread_id = thread_copy,
        .from = from_copy,
        .subject = subject_copy,
        .snippet = snippet_copy,
    };
}

fn findKnown(known: []const Entry, id: []const u8) ?*const Entry {
    for (known) |*k| {
        if (std.mem.eql(u8, k.id, id)) return k;
    }
    return null;
}

const EntryJson = struct {
    id: []const u8,
    thread_id: []const u8,
    from: []const u8,
    subject: []const u8,
    snippet: []const u8,
};

const cache_file = "messages.json";
const max_cache_size = 256 * 1024;

/// Fetches the current unread list and a preview of each message. The list
/// is always fetched fresh (it's what says which messages are still unread),
/// but a message's preview -- sender, subject, snippet -- never changes, so
/// any id already present in `known` (the previous cache) is reused as is
/// and only ids not seen before cost a getPreview call. A poll where
/// nothing new arrived is therefore one list call, not one plus a preview
/// per message. Pass `&.{}` to force every preview to be fetched.
///
/// Sequential on purpose (see popup.zig's fetchMessages for the history
/// there). Skips, rather than failing outright, any single message whose
/// preview fetch fails, so one bad message doesn't blank the whole list.
pub fn fetchFromApi(
    gpa: Allocator,
    client: *http.Client,
    access_token: []const u8,
    max_messages: u32,
    known: []const Entry,
) ![]Entry {
    const refs = try gmail.listUnread(gpa, client, access_token, max_messages);
    defer gmail.freeMessageRefs(gpa, refs);

    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |*e| e.deinit(gpa);
        out.deinit(gpa);
    }

    for (refs) |ref| {
        if (findKnown(known, ref.id)) |k| {
            try out.ensureUnusedCapacity(gpa, 1);
            out.appendAssumeCapacity(try makeEntry(gpa, ref.id, ref.thread_id, k.from, k.subject, k.snippet));
            continue;
        }
        var preview = gmail.getPreview(gpa, client, access_token, ref.id) catch continue;
        defer preview.deinit(gpa);
        try out.ensureUnusedCapacity(gpa, 1);
        out.appendAssumeCapacity(try makeEntry(gpa, ref.id, ref.thread_id, preview.from, preview.subject, preview.snippet));
    }
    return out.toOwnedSlice(gpa);
}

pub fn save(gpa: Allocator, io: Io, dir: Dir, entries: []const Entry) !void {
    var list: std.ArrayList(EntryJson) = .empty;
    defer list.deinit(gpa);
    for (entries) |e| {
        try list.append(gpa, .{ .id = e.id, .thread_id = e.thread_id, .from = e.from, .subject = e.subject, .snippet = e.snippet });
    }

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(list.items, .{}, &out.writer);
    try cache.atomicWrite(dir, io, cache_file, out.written(), cache.private_file_permissions);
}

/// How old the cache file may be and still be trusted as current. The 60s
/// status poll rewrites it on every run while anything is unread, so with
/// the default waybar interval its age never exceeds about a minute; the
/// extra headroom absorbs a slow poll without making the popup refetch.
pub const fresh_max_age_ms: i64 = 90_000;

/// Pure age check. A negative age means the file's mtime is in the future
/// (the clock was set back) -- that is not "fresh", it's "can't tell".
pub fn isFreshAge(now_ms: i64, mtime_ms: i64, max_age_ms: i64) bool {
    const age = now_ms - mtime_ms;
    return age >= 0 and age <= max_age_ms;
}

/// Whether the cache file was written recently enough that the popup can
/// paint from it and skip its own network refresh. A missing or unreadable
/// file is simply "not fresh".
pub fn isFresh(io: Io, dir: Dir, max_age_ms: i64) bool {
    const st = dir.statFile(io, cache_file, .{}) catch return false;
    const now = Io.Timestamp.now(io, .real);
    return isFreshAge(now.toMilliseconds(), st.mtime.toMilliseconds(), max_age_ms);
}

/// Returns null if there's no cache yet or it's unreadable/malformed --
/// both are normal, expected states, not errors.
pub fn load(gpa: Allocator, io: Io, dir: Dir) ?std.ArrayList(Entry) {
    const raw = gpa.alloc(u8, max_cache_size) catch return null;
    defer gpa.free(raw);
    const data = dir.readFile(io, cache_file, raw) catch return null;

    const parsed = std.json.parseFromSlice([]EntryJson, gpa, data, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    var out: std.ArrayList(Entry) = .empty;
    for (parsed.value) |m| {
        const entry: Entry = .{
            .id = gpa.dupe(u8, m.id) catch break,
            .thread_id = gpa.dupe(u8, m.thread_id) catch break,
            .from = gpa.dupe(u8, m.from) catch break,
            .subject = gpa.dupe(u8, m.subject) catch break,
            .snippet = gpa.dupe(u8, m.snippet) catch break,
        };
        out.append(gpa, entry) catch break;
    }
    return out;
}

/// A tooltip line longer than this is cut short with an ellipsis. Subjects
/// can be kilobytes long (the fixtures include a ~1.9KB one on purpose), and
/// a tooltip as wide as the screen is no use to anyone.
pub const max_tooltip_line_chars = 100;

/// The longest prefix of `text` with at most `max_chars` Unicode code points,
/// cut on a character boundary so the result is still valid UTF-8. `text`
/// itself if it already fits (or isn't valid UTF-8 at all, in which case it
/// is left alone rather than guessed at).
fn truncateUtf8(text: []const u8, max_chars: usize) []const u8 {
    var it = (std.unicode.Utf8View.init(text) catch return text).iterator();
    var chars: usize = 0;
    var end: usize = 0;
    while (it.nextCodepointSlice()) |slice| {
        if (chars == max_chars) return text[0..end];
        chars += 1;
        end += slice.len;
    }
    return text;
}

/// Builds the tooltip's per-message lines ("From — Subject") from
/// fetched entries -- the same format the popup has always written via
/// persistCaches, kept in one place so the two call sites can't drift
/// apart. Lines longer than `max_tooltip_line_chars` are shortened here
/// only: the cache keeps the full text for the popup. Caller owns the
/// result: free each line, then the slice.
pub fn buildTooltipLines(gpa: Allocator, entries: []const Entry) ![][]u8 {
    var lines: std.ArrayList([]u8) = .empty;
    errdefer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    for (entries) |e| {
        const full = try std.fmt.allocPrint(gpa, "{s} — {s}", .{ e.from, e.subject });
        const short = truncateUtf8(full, max_tooltip_line_chars);
        if (short.len == full.len) {
            lines.append(gpa, full) catch |err| {
                gpa.free(full);
                return err;
            };
            continue;
        }
        defer gpa.free(full);
        const line = try std.fmt.allocPrint(gpa, "{s}…", .{short});
        lines.append(gpa, line) catch |err| {
            gpa.free(line);
            return err;
        };
    }
    return lines.toOwnedSlice(gpa);
}

// ---- tests ----

const testing = std.testing;

fn writeFixture(dir: Dir, sub_path: []const u8, contents: []const u8) !void {
    if (Dir.path.dirname(sub_path)) |parent| {
        try dir.createDirPath(testing.io, parent);
    }
    try dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = contents });
}

fn fixtureClient(dir: Dir) !http.Client {
    const path_z = try dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(path_z);
    const path = try testing.allocator.dupe(u8, path_z);
    return http.Client.initFixture(testing.allocator, testing.io, path);
}

test "save then load round-trips entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const entries = [_]Entry{
        .{ .id = "id1", .thread_id = "t1", .from = "Alice <a@example.com>", .subject = "Hi", .snippet = "snip1" },
        .{ .id = "id2", .thread_id = "t2", .from = "Bob <b@example.com>", .subject = "Hey", .snippet = "snip2" },
    };
    try save(testing.allocator, testing.io, tmp.dir, &entries);

    var loaded = load(testing.allocator, testing.io, tmp.dir).?;
    defer {
        for (loaded.items) |*e| e.deinit(testing.allocator);
        loaded.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 2), loaded.items.len);
    try testing.expectEqualStrings("id1", loaded.items[0].id);
    try testing.expectEqualStrings("Bob <b@example.com>", loaded.items[1].from);
}

test "isFreshAge: recent is fresh, old is stale, a future mtime is not trusted" {
    try testing.expect(isFreshAge(100_000, 100_000, 90_000)); // just written
    try testing.expect(isFreshAge(100_000, 40_000, 90_000)); // 60s old
    try testing.expect(isFreshAge(190_000, 100_000, 90_000)); // exactly the limit
    try testing.expect(!isFreshAge(190_001, 100_000, 90_000)); // one ms over
    try testing.expect(!isFreshAge(100_000, 100_001, 90_000)); // mtime in the future
}

test "isFresh is true for a cache just written and false when there is none" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expect(!isFresh(testing.io, tmp.dir, fresh_max_age_ms));

    try save(testing.allocator, testing.io, tmp.dir, &.{});
    try testing.expect(isFresh(testing.io, tmp.dir, fresh_max_age_ms));
}

test "load returns null when no cache exists yet" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expect(load(testing.allocator, testing.io, tmp.dir) == null);
}

test "load returns null on malformed cache content" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = cache_file, .data = "not json" });
    try testing.expect(load(testing.allocator, testing.io, tmp.dir) == null);
}

test "buildTooltipLines formats From — Subject" {
    const entries = [_]Entry{
        .{ .id = "id1", .thread_id = "t1", .from = "GitHub", .subject = "PR merged", .snippet = "" },
    };
    const lines = try buildTooltipLines(testing.allocator, &entries);
    defer {
        for (lines) |l| testing.allocator.free(l);
        testing.allocator.free(lines);
    }
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqualStrings("GitHub — PR merged", lines[0]);
}

test "fetchFromApi fetches list and previews via fixtures" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "messages_list.json",
        \\{"status": 200, "body": {"messages": [{"id": "m1", "threadId": "t1"}]}}
    );
    try writeFixture(tmp.dir, "messages/m1.json",
        \\{"status": 200, "body": {"payload": {"headers": [{"name": "From", "value": "GitHub"}, {"name": "Subject", "value": "PR merged"}]}, "snippet": "Great work"}}
    );

    var client = try fixtureClient(tmp.dir);
    defer client.deinit();
    defer testing.allocator.free(client.mode.fixture);

    const entries = try fetchFromApi(testing.allocator, &client, "token", 15, &.{});
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("m1", entries[0].id);
    try testing.expectEqualStrings("GitHub", entries[0].from);
    try testing.expectEqualStrings("PR merged", entries[0].subject);
}

test "fetchFromApi reuses known previews and only fetches unseen ids" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The list has m1 (already cached) and m2 (new). Only m2 has a preview
    // fixture: if m1's preview were fetched again the fixture lookup would
    // fail and m1 would be skipped, so m1 appearing proves it came from `known`.
    try writeFixture(tmp.dir, "messages_list.json",
        \\{"status": 200, "body": {"messages": [{"id": "m2", "threadId": "t2"}, {"id": "m1", "threadId": "t1"}]}}
    );
    try writeFixture(tmp.dir, "messages/m2.json",
        \\{"status": 200, "body": {"payload": {"headers": [{"name": "From", "value": "New Sender"}, {"name": "Subject", "value": "Fresh"}]}, "snippet": "just arrived"}}
    );

    var client = try fixtureClient(tmp.dir);
    defer client.deinit();
    defer testing.allocator.free(client.mode.fixture);

    const known = [_]Entry{
        .{ .id = "m1", .thread_id = "t1", .from = "Cached Sender", .subject = "Cached subject", .snippet = "CACHED SNIPPET" },
        // Cached but no longer unread: must not reappear.
        .{ .id = "gone", .thread_id = "tg", .from = "x", .subject = "x", .snippet = "x" },
    };
    const entries = try fetchFromApi(testing.allocator, &client, "token", 15, &known);
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    // Order follows the fresh list, not the cache.
    try testing.expectEqualStrings("m2", entries[0].id);
    try testing.expectEqualStrings("Fresh", entries[0].subject);
    try testing.expectEqualStrings("m1", entries[1].id);
    try testing.expectEqualStrings("Cached Sender", entries[1].from);
    try testing.expectEqualStrings("CACHED SNIPPET", entries[1].snippet);
}

test "fetchFromApi still skips a new message whose preview fails" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "messages_list.json",
        \\{"status": 200, "body": {"messages": [{"id": "bad", "threadId": "tb"}]}}
    );
    // No messages/bad.json fixture at all.

    var client = try fixtureClient(tmp.dir);
    defer client.deinit();
    defer testing.allocator.free(client.mode.fixture);

    const entries = try fetchFromApi(testing.allocator, &client, "token", 15, &.{});
    defer freeEntries(testing.allocator, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "truncateUtf8 cuts on a character boundary" {
    try testing.expectEqualStrings("abc", truncateUtf8("abcdef", 3));
    try testing.expectEqualStrings("abcdef", truncateUtf8("abcdef", 6));
    try testing.expectEqualStrings("abcdef", truncateUtf8("abcdef", 100));
    try testing.expectEqualStrings("", truncateUtf8("abc", 0));
    // 2-byte and 4-byte characters are never split.
    try testing.expectEqualStrings("éé", truncateUtf8("ééé", 2));
    try testing.expectEqualStrings("\u{1F600}\u{1F600}", truncateUtf8("\u{1F600}\u{1F600}\u{1F600}", 2));
    // Not valid UTF-8: left alone rather than cut at a guess.
    try testing.expectEqualStrings("\xff\xfeabc", truncateUtf8("\xff\xfeabc", 1));
}

test "buildTooltipLines shortens very long lines but not short ones" {
    const long_subject = "x" ** 500;
    const accented = "é" ** 300;
    const entries = [_]Entry{
        .{ .id = "1", .thread_id = "t", .from = "A", .subject = "short", .snippet = "" },
        .{ .id = "2", .thread_id = "t", .from = "B", .subject = long_subject, .snippet = "" },
        .{ .id = "3", .thread_id = "t", .from = "C", .subject = accented, .snippet = "" },
    };
    const lines = try buildTooltipLines(testing.allocator, &entries);
    defer {
        for (lines) |l| testing.allocator.free(l);
        testing.allocator.free(lines);
    }
    try testing.expectEqualStrings("A — short", lines[0]);

    // 100 characters then the ellipsis (3 bytes).
    try testing.expect(std.mem.endsWith(u8, lines[1], "…"));
    try testing.expectEqual(@as(usize, 100 + "…".len), lines[1].len);

    try testing.expect(std.unicode.utf8ValidateSlice(lines[2]));
    try testing.expect(std.mem.endsWith(u8, lines[2], "…"));
    const kept = lines[2][0 .. lines[2].len - "…".len];
    try testing.expectEqual(@as(usize, 100), try std.unicode.utf8CountCodepoints(kept));
}
