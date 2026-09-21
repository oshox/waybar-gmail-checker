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

const EntryJson = struct {
    id: []const u8,
    thread_id: []const u8,
    from: []const u8,
    subject: []const u8,
    snippet: []const u8,
};

const cache_file = "messages.json";
const max_cache_size = 256 * 1024;

/// Fetches the current unread list and each message's preview: one
/// listUnread call plus one getPreview call per message, all
/// sequential -- deliberately not parallelized, see popup.zig's
/// fetchMessages for the history there. Skips (rather than failing
/// outright) any single message whose preview fetch fails, so one bad
/// message doesn't blank the whole list.
pub fn fetchFromApi(gpa: Allocator, client: *http.Client, access_token: []const u8, max_messages: u32) ![]Entry {
    const refs = try gmail.listUnread(gpa, client, access_token, max_messages);
    defer gmail.freeMessageRefs(gpa, refs);

    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |*e| e.deinit(gpa);
        out.deinit(gpa);
    }

    for (refs) |ref| {
        var preview = gmail.getPreview(gpa, client, access_token, ref.id) catch continue;
        defer preview.deinit(gpa);
        try out.append(gpa, .{
            .id = try gpa.dupe(u8, ref.id),
            .thread_id = try gpa.dupe(u8, ref.thread_id),
            .from = try gpa.dupe(u8, preview.from),
            .subject = try gpa.dupe(u8, preview.subject),
            .snippet = try gpa.dupe(u8, preview.snippet),
        });
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

/// Builds the tooltip's per-message lines ("From — Subject") from
/// fetched entries -- the same format the popup has always written via
/// persistCaches, kept in one place so the two call sites can't drift
/// apart. Caller owns the result: free each line, then the slice.
pub fn buildTooltipLines(gpa: Allocator, entries: []const Entry) ![][]u8 {
    var lines: std.ArrayList([]u8) = .empty;
    errdefer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    for (entries) |e| {
        const line = try std.fmt.allocPrint(gpa, "{s} — {s}", .{ e.from, e.subject });
        try lines.append(gpa, line);
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

    const entries = try fetchFromApi(testing.allocator, &client, "token", 15);
    defer freeEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("m1", entries[0].id);
    try testing.expectEqualStrings("GitHub", entries[0].from);
    try testing.expectEqualStrings("PR merged", entries[0].subject);
}
