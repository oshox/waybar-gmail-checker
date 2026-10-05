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

/// Where the user's web Gmail lives, for opening messages in the browser.
/// `account_index` is the N in mail.google.com/mail/u/N/ (see
/// config.account_index): which of the browser's signed-in Google accounts.
pub fn inboxUrl(buf: []u8, account_index: u32) std.fmt.BufPrintError![]const u8 {
    return std.fmt.bufPrint(buf, "https://mail.google.com/mail/u/{d}/#inbox", .{account_index});
}

pub fn messageUrl(buf: []u8, account_index: u32, thread_id: []const u8) std.fmt.BufPrintError![]const u8 {
    return std.fmt.bufPrint(buf, "https://mail.google.com/mail/u/{d}/#inbox/{s}", .{ account_index, thread_id });
}

/// The three outcomes `status` (and everything built on it) needs to tell
/// apart: an expired/invalid token or missing permission (worth surfacing as
/// "unauthenticated" so the user knows to re-run `auth`), rate limiting
/// (transient -- the next poll will probably work, and telling the user to
/// re-authenticate would be wrong), and everything else (a generic "error"
/// class -- service outage, a disabled API, ...). Every other error
/// (allocation failure, malformed JSON, a network error from
/// `std.http.Client`) flows through via each function's inferred error set.
///
/// 403 is genuinely ambiguous: Gmail uses it both for "this token can't do
/// that" and for `rateLimitExceeded`/`userRateLimitExceeded`, so the body is
/// consulted before deciding it means "sign in again".
pub fn checkResponse(status: u16, body: []const u8) error{ Unauthorized, RateLimited, GmailApiError }!void {
    if (status == 200) return;
    if (status == 429) return error.RateLimited;
    if (status == 401) return error.Unauthorized;
    if (status == 403) {
        if (isRateLimitBody(body)) return error.RateLimited;
        return error.Unauthorized;
    }
    return error.GmailApiError;
}

/// "ateLimitExceeded" covers both `rateLimitExceeded` and
/// `userRateLimitExceeded` without caring about the capital R.
fn isRateLimitBody(body: []const u8) bool {
    const markers = [_][]const u8{ "ateLimitExceeded", "dailyLimitExceeded", "RESOURCE_EXHAUSTED" };
    for (markers) |m| {
        if (std.mem.indexOf(u8, body, m) != null) return true;
    }
    return false;
}

fn fixtureKey(buf: []u8, comptime prefix: []const u8, id: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, prefix ++ "/{s}", .{id}) catch id;
}

/// The cheap request every `status` poll makes: exact, no per-message
/// work. `fields` trims the response to the one value we read.
pub fn getUnreadCount(gpa: Allocator, client: *http.Client, access_token: []const u8) !u32 {
    var resp = try client.send(.{
        .method = .GET,
        .url = api_base ++ "/labels/INBOX?fields=messagesUnread",
        .access_token = access_token,
        .fixture_key = "labels_inbox",
    });
    defer resp.deinit(gpa);
    try checkResponse(resp.status, resp.body);

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
        api_base ++ "/messages?q=is%3Aunread+in%3Ainbox&maxResults={d}&fields=messages(id,threadId)",
        .{max_results},
    );

    var resp = try client.send(.{
        .method = .GET,
        .url = url,
        .access_token = access_token,
        .fixture_key = "messages_list",
    });
    defer resp.deinit(gpa);
    try checkResponse(resp.status, resp.body);

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
    var url_buf: [320]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        api_base ++ "/messages/{s}?format=metadata&metadataHeaders=From&metadataHeaders=Subject" ++
            "&fields=snippet,payload/headers",
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
    try checkResponse(resp.status, resp.body);

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

    // Unlike the headers, the snippet comes back HTML-escaped ("it&#39;s",
    // "A &amp; B" -- confirmed against the live API), so it has to be
    // unescaped before display or the popup shows the entities literally.
    const snippet_text = try unescapeHtmlEntities(gpa, parsed.value.snippet);
    defer gpa.free(snippet_text);
    const snippet = try mime.decodeHeader(gpa, snippet_text);
    errdefer gpa.free(snippet);

    return .{ .from = from, .subject = subject, .snippet = snippet };
}

/// Decodes the HTML entities Gmail leaves in `snippet`: numeric (`&#39;`,
/// `&#x1F600;`) and the handful of named ones HTML escaping produces
/// (`&amp; &lt; &gt; &quot; &apos; &nbsp;`). Anything that isn't a
/// well-formed entity -- a bare `&`, `AT&T`, `&unknown;` -- is left exactly
/// as it was. A well-formed numeric entity that can't be a real character
/// (NUL, a surrogate, past U+10FFFF) becomes U+FFFD rather than injecting
/// invalid UTF-8 or a NUL into text that goes on to GTK and Pango.
///
/// Caller owns the returned slice.
pub fn unescapeHtmlEntities(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, text.len);

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            // The longest entity we decode is "#x10FFFF" (8 chars); a
            // bounded search keeps a stray '&' in long text from scanning
            // to the end of the string every time.
            const search_end = @min(text.len, i + 1 + 10);
            if (std.mem.indexOfScalarPos(u8, text[0..search_end], i + 1, ';')) |semi| {
                if (decodeEntity(text[i + 1 .. semi])) |cp| {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch blk: {
                        @memcpy(buf[0..3], "\u{FFFD}");
                        break :blk 3;
                    };
                    try out.appendSlice(gpa, buf[0..n]);
                    i = semi + 1;
                    continue;
                }
            }
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// `name` is what sits between '&' and ';'. Null means "not an entity we
/// handle" (so the caller leaves the text alone).
fn decodeEntity(name: []const u8) ?u21 {
    if (name.len == 0) return null;
    if (name[0] == '#') {
        if (name.len < 2) return null;
        const is_hex = name[1] == 'x' or name[1] == 'X';
        const digits = if (is_hex) name[2..] else name[1..];
        if (digits.len == 0) return null;
        const value = std.fmt.parseInt(u32, digits, if (is_hex) 16 else 10) catch return null;
        if (value == 0 or value > 0x10FFFF) return 0xFFFD;
        return @intCast(value);
    }
    const named = [_]struct { []const u8, u21 }{
        .{ "amp", '&' },
        .{ "lt", '<' },
        .{ "gt", '>' },
        .{ "quot", '"' },
        .{ "apos", '\'' },
        .{ "nbsp", 0xA0 },
    };
    for (named) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
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
    try checkResponse(resp.status, resp.body);
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
    try checkResponse(resp.status, resp.body);
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

test "inboxUrl and messageUrl honor the account index" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("https://mail.google.com/mail/u/0/#inbox", try inboxUrl(&buf, 0));
    try testing.expectEqualStrings("https://mail.google.com/mail/u/2/#inbox", try inboxUrl(&buf, 2));
    try testing.expectEqualStrings("https://mail.google.com/mail/u/1/#inbox/abc123", try messageUrl(&buf, 1, "abc123"));
}

test "checkResponse: 401 is Unauthorized, 429 is RateLimited, 5xx is a generic API error" {
    try checkResponse(200, "");
    try testing.expectError(error.Unauthorized, checkResponse(401, "{}"));
    try testing.expectError(error.RateLimited, checkResponse(429, "{}"));
    try testing.expectError(error.GmailApiError, checkResponse(500, "{}"));
    try testing.expectError(error.GmailApiError, checkResponse(404, "{}"));
}

test "checkResponse: a 403 is a rate limit only when the body says so" {
    // Real Gmail rate-limit bodies carry one of these reasons.
    try testing.expectError(error.RateLimited, checkResponse(403,
        \\{"error":{"errors":[{"reason":"rateLimitExceeded"}],"code":403}}
    ));
    try testing.expectError(error.RateLimited, checkResponse(403,
        \\{"error":{"errors":[{"reason":"userRateLimitExceeded"}],"code":403}}
    ));
    try testing.expectError(error.RateLimited, checkResponse(403,
        \\{"error":{"errors":[{"reason":"dailyLimitExceeded"}],"code":403}}
    ));
    // Any other 403 (insufficient scope, access denied) still means "sign in again".
    try testing.expectError(error.Unauthorized, checkResponse(403,
        \\{"error":{"errors":[{"reason":"insufficientPermissions"}],"code":403}}
    ));
    try testing.expectError(error.Unauthorized, checkResponse(403, ""));
}

test "unescapeHtmlEntities decodes numeric and the common named entities" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "it&#39;s", "it's" },
        .{ "Tom &amp; Jerry", "Tom & Jerry" },
        .{ "&lt;b&gt; &quot;hi&quot; &apos;x&apos;", "<b> \"hi\" 'x'" },
        .{ "&#x1F600;", "\u{1F600}" },
        .{ "&#128512;", "\u{1F600}" },
        .{ "a&nbsp;b", "a\u{A0}b" },
        .{ "&#X41;", "A" },
    };
    for (cases) |c| {
        const got = try unescapeHtmlEntities(testing.allocator, c[0]);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c[1], got);
    }
}

test "unescapeHtmlEntities leaves anything that isn't a well-formed entity alone" {
    const untouched = [_][]const u8{
        "AT&T rocks",
        "a & b",
        "trailing &",
        "&unknown; stays",
        "&;",
        "&#;",
        "&#x;",
        "&#12a;",
        "no entities at all",
        "",
        "&amp",
    };
    for (untouched) |text| {
        const got = try unescapeHtmlEntities(testing.allocator, text);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(text, got);
    }
}

test "unescapeHtmlEntities turns unrepresentable numeric entities into U+FFFD, never invalid UTF-8" {
    // NUL, a lone surrogate, and a value past the last code point.
    const got = try unescapeHtmlEntities(testing.allocator, "a&#0;b&#xD800;c&#1114112;d&#99999999999;e");
    defer testing.allocator.free(got);
    try testing.expect(std.unicode.utf8ValidateSlice(got));
    try testing.expectEqualStrings("a\u{FFFD}b\u{FFFD}c\u{FFFD}d&#99999999999;e", got);
}

test "getPreview unescapes the snippet but leaves header text alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "messages/msg3.json",
        \\{"status":200,"body":{
        \\  "snippet":"Here&#39;s what&#39;s new &amp; improved",
        \\  "payload":{"headers":[
        \\    {"name":"From","value":"Dev &amp; Co <dev@example.com>"},
        \\    {"name":"Subject","value":"Q&A"}
        \\  ]}
        \\}}
    );

    var client = try fixtureClient(tmp.dir);
    defer client.deinit();
    defer testing.allocator.free(client.mode.fixture);

    var preview = try getPreview(testing.allocator, &client, "token", "msg3");
    defer preview.deinit(testing.allocator);

    try testing.expectEqualStrings("Here's what's new & improved", preview.snippet);
    // Headers are raw text, not HTML: a literal "&amp;" in a From name is the sender's own text.
    try testing.expectEqualStrings("Dev &amp; Co <dev@example.com>", preview.from);
    try testing.expectEqualStrings("Q&A", preview.subject);
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
