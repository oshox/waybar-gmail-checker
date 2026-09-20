//! Thin HTTP client wrapper with a fixture-mode seam: every network call in
//! this project goes through `Client.send`, so setting
//! `WAYBAR_GMAIL_FIXTURE=<dir>` makes the entire Gmail client (and
//! everything built on it -- status, popup, actions) testable without a
//! network connection or a Google account.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Response = struct {
    status: u16,
    /// Raw JSON response body. Caller owns.
    body: []u8,

    pub fn deinit(self: *Response, gpa: Allocator) void {
        gpa.free(self.body);
        self.* = undefined;
    }
};

pub const Request = struct {
    method: std.http.Method,
    /// Full URL. Used only in live mode.
    url: []const u8,
    /// Bearer token. Used only in live mode.
    access_token: []const u8,
    /// JSON request body, for POST calls. Used only in live mode.
    json_body: ?[]const u8 = null,
    /// Fixture file name (without ".json"), read from the fixture
    /// directory as `<dir>/<fixture_key>.json`. Used only in fixture mode.
    ///
    /// Every call site names its own fixture explicitly rather than this
    /// module trying to derive one from the URL: Gmail URLs embed message
    /// ids that vary per test, so a generic URL->fixture mapping would just
    /// push the same naming problem down a level.
    fixture_key: []const u8,
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    mode: Mode,

    pub const Mode = union(enum) {
        live: std.http.Client,
        /// Fixture directory path.
        fixture: []const u8,
    };

    pub fn initLive(gpa: Allocator, io: Io) Client {
        return .{ .gpa = gpa, .io = io, .mode = .{ .live = .{ .allocator = gpa, .io = io } } };
    }

    pub fn initFixture(gpa: Allocator, io: Io, fixture_dir: []const u8) Client {
        return .{ .gpa = gpa, .io = io, .mode = .{ .fixture = fixture_dir } };
    }

    /// Reads `WAYBAR_GMAIL_FIXTURE` from the environment and picks the
    /// right mode -- the one seam every subcommand's entry point uses.
    pub fn initFromEnv(gpa: Allocator, io: Io, environ_map: *const std.process.Environ.Map) Client {
        if (environ_map.get("WAYBAR_GMAIL_FIXTURE")) |dir| {
            if (dir.len > 0) return initFixture(gpa, io, dir);
        }
        return initLive(gpa, io);
    }

    pub fn deinit(self: *Client) void {
        switch (self.mode) {
            .live => |*c| c.deinit(),
            .fixture => {},
        }
    }

    pub fn send(self: *Client, req: Request) !Response {
        return switch (self.mode) {
            .live => |*c| self.sendLive(c, req),
            .fixture => |dir| self.sendFixture(dir, req),
        };
    }

    fn sendLive(self: *Client, http_client: *std.http.Client, req: Request) !Response {
        var auth_buf: [4096]u8 = undefined;
        const auth_header = try std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{req.access_token});

        var extra_headers_buf: [2]std.http.Header = undefined;
        var n_headers: usize = 0;
        extra_headers_buf[n_headers] = .{ .name = "authorization", .value = auth_header };
        n_headers += 1;
        if (req.json_body != null) {
            extra_headers_buf[n_headers] = .{ .name = "content-type", .value = "application/json; charset=utf-8" };
            n_headers += 1;
        }

        var response_body: Io.Writer.Allocating = .init(self.gpa);
        errdefer response_body.deinit();

        const result = try http_client.fetch(.{
            .location = .{ .url = req.url },
            .method = req.method,
            .payload = req.json_body,
            .extra_headers = extra_headers_buf[0..n_headers],
            .response_writer = &response_body.writer,
        });

        return .{
            .status = @intFromEnum(result.status),
            .body = try response_body.toOwnedSlice(),
        };
    }

    const FixtureEnvelope = struct {
        status: u16,
        body: std.json.Value,
    };

    /// Fixture files are a small envelope so error paths (401, 403, 500,
    /// ...) are just as testable as success: `{"status": 200, "body": {...
    /// the real Gmail API response shape ...}}`.
    fn sendFixture(self: *Client, dir: []const u8, req: Request) !Response {
        var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.json", .{ dir, req.fixture_key }) catch
            return error.NameTooLong;

        const raw = self.gpa.alloc(u8, 256 * 1024) catch |err| return err;
        defer self.gpa.free(raw);
        const file_data = Io.Dir.cwd().readFile(self.io, path, raw) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("waybar-gmail: missing fixture '{s}'\n", .{path});
                return err;
            },
            else => return err,
        };

        const parsed = try std.json.parseFromSlice(FixtureEnvelope, self.gpa, file_data, .{});
        defer parsed.deinit();

        var out: Io.Writer.Allocating = .init(self.gpa);
        errdefer out.deinit();
        try std.json.Stringify.value(parsed.value.body, .{}, &out.writer);

        return .{
            .status = parsed.value.status,
            .body = try out.toOwnedSlice(),
        };
    }
};

// ---- tests ----

const testing = std.testing;

test "fixture mode reads the envelope and re-serializes the body" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "labels_inbox.json",
        .data = "{\"status\":200,\"body\":{\"messagesUnread\":3}}",
    });

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var client = Client.initFixture(testing.allocator, testing.io, dir_path);
    defer client.deinit();

    var resp = try client.send(.{
        .method = .GET,
        .url = "unused-in-fixture-mode",
        .access_token = "unused-in-fixture-mode",
        .fixture_key = "labels_inbox",
    });
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 200), resp.status);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, resp.body, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 3), parsed.value.object.get("messagesUnread").?.integer);
}

test "fixture mode reports non-200 status without erroring" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "unauthorized.json",
        .data = "{\"status\":401,\"body\":{\"error\":{\"message\":\"invalid credentials\"}}}",
    });

    const dir_path = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir_path);

    var client = Client.initFixture(testing.allocator, testing.io, dir_path);
    defer client.deinit();

    var resp = try client.send(.{
        .method = .GET,
        .url = "unused",
        .access_token = "unused",
        .fixture_key = "unauthorized",
    });
    defer resp.deinit(testing.allocator);

    try testing.expectEqual(@as(u16, 401), resp.status);
}

test "initFromEnv picks fixture mode when the env var is set" {
    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();
    try map.put("WAYBAR_GMAIL_FIXTURE", "/some/dir");

    var client = Client.initFromEnv(testing.allocator, testing.io, &map);
    defer client.deinit();

    try testing.expect(client.mode == .fixture);
    try testing.expectEqualStrings("/some/dir", client.mode.fixture);
}

test "initFromEnv picks live mode when the env var is absent" {
    var map: std.process.Environ.Map = .init(testing.allocator);
    defer map.deinit();

    var client = Client.initFromEnv(testing.allocator, testing.io, &map);
    defer client.deinit();

    try testing.expect(client.mode == .live);
}
