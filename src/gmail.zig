//! Gmail API calls: unread count, listing, previews, and the three
//! mutating actions (mark-read, archive, trash). Every call goes through
//! `http.Client`, so it's exercised identically whether that client is
//! live or fixture-backed.
//!
//! Fixture keys are derived automatically from the operation and message
//! id (e.g. `messages/<id>`, `modify/<id>`) so nothing above this module
//! needs to know fixture mode exists at all -- callers just call
//! `getPreview(gpa, client, token, id)` the same way in both modes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("http.zig");
const mime = @import("mime.zig");

const api_base = "https://gmail.googleapis.com/gmail/v1/users/me";

/// The two outcomes M3's `status` (and everything built on it) needs to
/// tell apart: an expired/invalid token (worth surfacing as
/// "unauthenticated" so the user knows to re-run `auth`) versus everything
/// else (a generic "error" class -- rate limiting, service outage, a
/// disabled API, ...). Every other error (allocation failure, malformed
/// JSON, a network error from `std.http.Client`) flows through via each
/// function's inferred error set.
pub fn checkStatus(status: u16) error{ Unauthorized, GmailApiError }!void {
    if (status == 200) return;
    if (status == 401 or status == 403) return error.Unauthorized;
    return error.GmailApiError;
}

fn fixtureKey(buf: []u8, comptime prefix: []const u8, id: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "/{s}", .{id}) catch id;
}

/// The single request `status` makes: exact, cheap, no per-message work.
pub fn getUnreadCount(gpa: Allocator, client: *http.Client, access_token: []const u8) !u32 {
    var resp = try client.send(.{
        .method = .GET,
        .url = api_base ++ "/labels/INBOX",
        .access_token = access_token,
        .fixture_key = "labels_inbox",
    });
    defer resp.deinit(gpa);
    try checkStatus(resp.status);

    const Shape = struct { messagesUnread: u32 = 0 };
    const parsed = try std.json.parseFromSlice(Shape, gpa, resp.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return parsed.value.messagesUnread;
}

pub const MessageRef = struct {
    id: []u8,
    thread_id: []u8,

    pub fn deinit(self: *MessageRef, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.thread_id);
        self.* = undefined;
    }
};

pub fn freeMessageRefs(gpa: Allocator, refs: []MessageRef) void {
    for (refs) |*r| r.deinit(gpa);
    gpa.free(refs);
}

/// Lists up to `max_results` unread inbox messages (id + thread id only;
/// see `getPreview` for headers/snippet). Caller owns the result --
/// free with `freeMessageRefs`.
pub fn listUnread(gpa: Allocator, client: *http.Client, access_token: []const u8, max_results: u32) ![]MessageRef {
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        api_base ++ "/messages?q=is%3Aunread+in%3Ainbox&maxResults={d}",
        .{max_results},
    );

    var resp = try client.send(.{
        .method = .GET,
        .url = url,
        .access_token = access_token,
        .fixture_key = "messages_list",
    });
    defer resp.deinit(gpa);
    try checkStatus(resp.status);

    const Shape = struct {
        messages: []struct { id: []const u8, threadId: []const u8 } = &.{},
    };
    const parsed = try std.json.parseFromSlice(Shape, gpa, resp.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var out = try gpa.alloc(MessageRef, parsed.value.messages.len);
    var filled: usize = 0;
    errdefer freeMessageRefs(gpa, out[0..filled]);
    for (parsed.value.messages) |m| {
        out[filled] = .{
            .id = try gpa.dupe(u8, m.id),
            .thread_id = try gpa.dupe(u8, m.threadId),
        };
        filled += 1;
    }
    return out;
}

pub const MessagePreview = struct {
    from: []u8,
    subject: []u8,
    snippet: []u8,

    pub fn deinit(self: *MessagePreview, gpa: Allocator) void {
        gpa.free(self.from);
        gpa.free(self.subject);
        gpa.free(self.snippet);
        self.* = undefined;
    }
};

/// Fetches From/Subject headers and the snippet for one message. Headers
/// are RFC 2047-decoded via mime.zig; the snippet is plain text from
/// Gmail but is passed through the same decoder anyway, since that's also
/// where the final valid-UTF-8 guarantee lives (decodeHeader is a no-op
/// pass-through-plus-sanitize on text with no "=?...?=" spans in it).
pub fn getPreview(gpa: Allocator, client: *http.Client, access_token: []const u8, id: []const u8) !MessagePreview {
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        api_base ++ "/messages/{s}?format=metadata&metadataHeaders=From&metadataHeaders=Subject",
        .{id},
    );
    var fixture_buf: [256]u8 = undefined;

    var resp = try client.send(.{
        .method = .GET,
        .url = url,
        .access_token = access_token,
        .fixture_key = fixtureKey(&fixture_buf, "messages", id),
    });
    defer resp.deinit(gpa);
    try checkStatus(resp.status);

    const HeaderShape = struct { name: []const u8, value: []const u8 };
    const Shape = struct {
        snippet: []const u8 = "",
        payload: struct {
            headers: []HeaderShape = &.{},
        } = .{},
    };
    const parsed = try std.json.parseFromSlice(Shape, gpa, resp.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var from_raw: []const u8 = "(unknown sender)";
    var subject_raw: []const u8 = "(no subject)";
    for (parsed.value.payload.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "From")) from_raw = h.value;
        if (std.ascii.eqlIgnoreCase(h.name, "Subject")) subject_raw = h.value;
    }

    const from = try mime.decodeHeader(gpa, from_raw);
    errdefer gpa.free(from);
    const subject = try mime.decodeHeader(gpa, subject_raw);
    errdefer gpa.free(subject);
    const snippet = try mime.decodeHeader(gpa, parsed.value.snippet);
    errdefer gpa.free(snippet);

    return .{ .from = from, .subject = subject, .snippet = snippet };
}

fn modify(gpa: Allocator, client: *http.Client, access_token: []const u8, id: []const u8, json_body: []const u8) !void {
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, api_base ++ "/messages/{s}/modify", .{id});
    var fixture_buf: [256]u8 = undefined;

    var resp = try client.send(.{
        .method = .POST,
        .url = url,
        .access_token = access_token,
        .json_body = json_body,
        .fixture_key = fixtureKey(&fixture_buf, "modify", id),
    });
    defer resp.deinit(gpa);
    try checkStatus(resp.status);
}

pub fn markRead(gpa: Allocator, client: *http.Client, access_token: []const u8, id: []const u8) !void {
    return modify(gpa, client, access_token, id, "{\"removeLabelIds\":[\"UNREAD\"]}");
}

pub fn archive(gpa: Allocator, client: *http.Client, access_token: []const u8, id: []const u8) !void {
    return modify(gpa, client, access_token, id, "{\"removeLabelIds\":[\"INBOX\",\"UNREAD\"]}");
}

/// Moves a message to Trash -- recoverable, matching what Gmail's own UI
/// does for its delete action. Deliberately not permanent deletion (which
/// would also need a broader OAuth scope than gmail.modify).
pub fn trash(gpa: Allocator, client: *http.Client, access_token: []const u8, id: []const u8) !void {
    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, api_base ++ "/messages/{s}/trash", .{id});
    var fixture_buf: [256]u8 = undefined;

    var resp = try client.send(.{
        .method = .POST,
        .url = url,
        .access_token = access_token,
        // The trash endpoint takes no meaningful body, unlike modify's
        // label-change payload, but Google's frontend rejects a bodiless
        // POST outright: 411 Length Required, "POST requests require a
        // Content-length header" -- confirmed live against the real API.
        // sendLive doesn't set Content-Length for a null payload, so an
        // explicit empty JSON body (which does get one) is required here
        // even though the server ignores its content.
        .json_body = "{}",
        .fixture_key = fixtureKey(&fixture_buf, "trash", id),
    });
    defer resp.deinit(gpa);
    try checkStatus(resp.status);
}

// ---- tests ----

const testing = std.testing;

fn writeFixture(dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    if (std.Io.Dir.path.dirname(sub_path)) |parent| {
        try dir.createDirPath(testing.io, parent);
    }
    try dir.writeFile(testing.io, .{ .sub_path = sub_path, .data = data });
}

fn fixtureClient(dir: std.Io.Dir) !http.Client {
    // realPathFileAlloc returns a sentinel-terminated [:0]u8; Client.Mode.fixture
    // is a plain []const u8, so the sentinel slice is duped into a plain one
    // and freed immediately here rather than coerced and freed later at its
    // wrong (unaccounted-for-sentinel) length.
    const path_z = try dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(path_z);
    const path = try testing.allocator.dupe(u8, path_z);
    return http.Client.initFixture(testing.allocator, testing.io, path);
}

test "getUnreadCount parses messagesUnread" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "labels_inbox.json", "{\"status\":200,\"body\":{\"messagesUnread\":7}}");

    var client = try fixtureClient(tmp.dir);
    defer client.deinit();
    defer testing.allocator.free(client.mode.fixture);

    const count = try getUnreadCount(testing.allocator, &client, "token");
    try testing.expectEqual(@as(u32, 7), count);
}

test "getUnreadCount maps 401 to Unauthorized" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "labels_inbox.json", "{\"status\":401,\"body\":{}}");

    var client = try fixtureClient(tmp.dir);
    defer client.deinit();
    defer testing.allocator.free(client.mode.fixture);

    try testing.expectError(error.Unauthorized, getUnreadCount(testing.allocator, &client, "token"));
}

test "getUnreadCount maps other non-200 to GmailApiError" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "labels_inbox.json", "{\"status\":500,\"body\":{}}");

    var client = try fixtureClient(tmp.dir);
    defer client.deinit();
    defer testing.allocator.free(client.mode.fixture);

    try testing.expectError(error.GmailApiError, getUnreadCount(testing.allocator, &client, "token"));
}

test "listUnread parses message id/threadId pairs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "messages_list.json",
        \\{"status":200,"body":{"messages":[
        \\  {"id":"msg1","threadId":"t1"},
        \\  {"id":"msg2","threadId":"t2"}
        \\]}}
    );

    var client = try fixtureClient(tmp.dir);
    defer client.deinit();
    defer testing.allocator.free(client.mode.fixture);

    const refs = try listUnread(testing.allocator, &client, "token", 15);
    defer freeMessageRefs(testing.allocator, refs);

    try testing.expectEqual(@as(usize, 2), refs.len);
    try testing.expectEqualStrings("msg1", refs[0].id);
    try testing.expectEqualStrings("t1", refs[0].thread_id);
    try testing.expectEqualStrings("msg2", refs[1].id);
    try testing.expectEqualStrings("t2", refs[1].thread_id);
}

test "listUnread on an empty inbox returns an empty slice, not an error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "messages_list.json", "{\"status\":200,\"body\":{}}");

    var client = try fixtureClient(tmp.dir);
    defer client.deinit();
    defer testing.allocator.free(client.mode.fixture);

    const refs = try listUnread(testing.allocator, &client, "token", 15);
    defer freeMessageRefs(testing.allocator, refs);
    try testing.expectEqual(@as(usize, 0), refs.len);
}

test "getPreview decodes RFC 2047 headers and picks the right fixture by id" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "messages/msg1.json",
        \\{"status":200,"body":{
        \\  "snippet":"a quick preview",
        \\  "payload":{"headers":[
        \\    {"name":"From","value":"=?UTF-8?B?R2l0SHVi?= <notify@github.com>"},
        \\    {"name":"Subject","value":"=?UTF-8?Q?PR_=2342_merged?="}
        \\  ]}
        \\}}
    );

    var client = try fixtureClient(tmp.dir);
    defer client.deinit();
    defer testing.allocator.free(client.mode.fixture);

    var preview = try getPreview(testing.allocator, &client, "token", "msg1");
    defer preview.deinit(testing.allocator);

    try testing.expectEqualStrings("GitHub <notify@github.com>", preview.from);
    try testing.expectEqualStrings("PR #42 merged", preview.subject);
    try testing.expectEqualStrings("a quick preview", preview.snippet);
}

test "getPreview falls back to placeholders when headers are missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "messages/msg2.json", "{\"status\":200,\"body\":{\"payload\":{\"headers\":[]}}}");

    var client = try fixtureClient(tmp.dir);
    defer client.deinit();
    defer testing.allocator.free(client.mode.fixture);

    var preview = try getPreview(testing.allocator, &client, "token", "msg2");
    defer preview.deinit(testing.allocator);

    try testing.expectEqualStrings("(unknown sender)", preview.from);
    try testing.expectEqualStrings("(no subject)", preview.subject);
    try testing.expectEqualStrings("", preview.snippet);
}

test "markRead sends the UNREAD-removal body and succeeds on 200" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "modify/msg1.json", "{\"status\":200,\"body\":{\"id\":\"msg1\"}}");

    var client = try fixtureClient(tmp.dir);
    defer client.deinit();
    defer testing.allocator.free(client.mode.fixture);

    try markRead(testing.allocator, &client, "token", "msg1");
}

test "archive succeeds on 200" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "modify/msg1.json", "{\"status\":200,\"body\":{\"id\":\"msg1\"}}");

    var client = try fixtureClient(tmp.dir);
    defer client.deinit();
    defer testing.allocator.free(client.mode.fixture);

    try archive(testing.allocator, &client, "token", "msg1");
}

test "trash succeeds on 200" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "trash/msg1.json", "{\"status\":200,\"body\":{\"id\":\"msg1\"}}");

    var client = try fixtureClient(tmp.dir);
    defer client.deinit();
    defer testing.allocator.free(client.mode.fixture);

    try trash(testing.allocator, &client, "token", "msg1");
}

test "an action against a failing id surfaces Unauthorized without corrupting state" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "trash/msg-bad.json", "{\"status\":401,\"body\":{}}");

    var client = try fixtureClient(tmp.dir);
    defer client.deinit();
    defer testing.allocator.free(client.mode.fixture);

    try testing.expectError(error.Unauthorized, trash(testing.allocator, &client, "token", "msg-bad"));
}
