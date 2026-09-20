//! Google OAuth: the installed-app loopback + PKCE consent flow, token
//! exchange/refresh, and the on-disk access-token cache. The refresh token
//! itself never touches disk -- it lives only in the keyring via
//! secrets.zig.
//!
//! Split by testability: URL/query construction, PKCE, and JSON
//! (de)serialization are pure and unit-tested here. The two live network
//! calls (token exchange, token refresh) and the interactive loopback
//! listener are exercised by the opportunistic-auth attempt (M2) and the
//! real `auth` subcommand (M8) instead -- there's no fixture seam for
//! Google's OAuth endpoints themselves, since the one remaining gate in
//! this whole project is a human clicking "Allow" in a browser once.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const cache = @import("cache.zig");
const secrets = @import("secrets.zig");

pub const secret_service = "waybar-gmail";
/// This tool manages exactly one Gmail inbox, so the keyring entry doesn't
/// need to be keyed by an actual email address (which the gmail.modify
/// scope alone doesn't even give us back from the token endpoint) -- a
/// fixed tag is simpler and makes the keyring lookup independent of
/// whichever account the user consents with.
pub const secret_account = "default";
pub const oauth_scope = "https://www.googleapis.com/auth/gmail.modify";

pub const ClientCredentials = struct {
    client_id: []u8,
    client_secret: []u8,
    auth_uri: []u8,
    token_uri: []u8,

    pub fn deinit(self: *ClientCredentials, gpa: Allocator) void {
        gpa.free(self.client_id);
        gpa.free(self.client_secret);
        gpa.free(self.auth_uri);
        gpa.free(self.token_uri);
        self.* = undefined;
    }
};

const max_credentials_file_size = 16 * 1024;

/// Parses Google's "installed app" client_secret.json shape:
/// `{"installed": {"client_id": ..., "client_secret": ..., "auth_uri": ...,
/// "token_uri": ..., "redirect_uris": [...]}}`. Read directly from this
/// file rather than duplicating the values into our own config, so
/// Google's credential file stays the single source of truth and can be
/// replaced independently of ~/.config/waybar-gmail/config.json.
pub fn loadClientCredentials(gpa: Allocator, io: Io, dir: Dir, file_name: []const u8) !ClientCredentials {
    var buf: [max_credentials_file_size + 1]u8 = undefined;
    const data = try cache.readBounded(dir, io, file_name, &buf);

    const Shape = struct {
        installed: struct {
            client_id: []const u8,
            client_secret: []const u8,
            auth_uri: []const u8,
            token_uri: []const u8,
        },
    };
    const parsed = try std.json.parseFromSlice(Shape, gpa, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    return .{
        .client_id = try gpa.dupe(u8, parsed.value.installed.client_id),
        .client_secret = try gpa.dupe(u8, parsed.value.installed.client_secret),
        .auth_uri = try gpa.dupe(u8, parsed.value.installed.auth_uri),
        .token_uri = try gpa.dupe(u8, parsed.value.installed.token_uri),
    };
}

// ---- PKCE (RFC 7636) ----

/// A 32-byte random value, base64url-no-pad encoded, is a valid verifier
/// under RFC 7636 (43 chars, well within the 43-128 range) without needing
/// to hand-pick from the allowed character set.
pub fn generateCodeVerifier(io: Io, buf: *[43]u8) []const u8 {
    var random_bytes: [32]u8 = undefined;
    io.random(&random_bytes);
    return std.base64.url_safe_no_pad.Encoder.encode(buf, &random_bytes);
}

/// code_challenge = BASE64URL-ENCODE(SHA256(code_verifier)), per RFC 7636
/// with the S256 method.
pub fn computeCodeChallenge(verifier: []const u8, buf: *[43]u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    return std.base64.url_safe_no_pad.Encoder.encode(buf, &digest);
}

/// Percent-encodes `input` per RFC 3986's unreserved set (ALPHA / DIGIT /
/// "-" / "." / "_" / "~"); everything else becomes %XX. Used for query
/// parameter values we build ourselves (redirect_uri, scope), since
/// `std.Uri`'s helpers are built around parsing URIs, not constructing
/// query strings from scratch.
pub fn percentEncode(gpa: Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (input) |b| {
        const unreserved = switch (b) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
            else => false,
        };
        if (unreserved) {
            try out.append(gpa, b);
        } else {
            try out.print(gpa, "%{X:0>2}", .{b});
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Builds the full Google consent-page URL for the loopback flow.
pub fn buildAuthorizationUrl(
    gpa: Allocator,
    auth_uri: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    code_challenge: []const u8,
    state: []const u8,
) ![]u8 {
    const enc_redirect = try percentEncode(gpa, redirect_uri);
    defer gpa.free(enc_redirect);
    const enc_scope = try percentEncode(gpa, oauth_scope);
    defer gpa.free(enc_scope);
    const enc_client_id = try percentEncode(gpa, client_id);
    defer gpa.free(enc_client_id);
    const enc_state = try percentEncode(gpa, state);
    defer gpa.free(enc_state);

    return std.fmt.allocPrint(
        gpa,
        "{s}?response_type=code&client_id={s}&redirect_uri={s}&scope={s}" ++
            "&code_challenge={s}&code_challenge_method=S256&access_type=offline" ++
            "&prompt=consent&state={s}",
        .{ auth_uri, enc_client_id, enc_redirect, enc_scope, code_challenge, enc_state },
    );
}

// ---- Loopback HTTP request parsing ----

/// Extracts the request target (e.g. "/?code=abc&state=xyz") from an HTTP
/// request line ("GET /?code=abc&state=xyz HTTP/1.1"). Returns null if the
/// line doesn't look like a well-formed request line.
pub fn extractRequestTarget(request_line: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, request_line, ' ');
    _ = it.next() orelse return null; // method
    return it.next(); // target
}

/// Finds `key`'s value in a request target's query string, still
/// percent-encoded. Returns null if `key` isn't present.
fn findRawQueryParam(target: []const u8, key: []const u8) ?[]const u8 {
    const query_start = (std.mem.indexOfScalar(u8, target, '?') orelse return null) + 1;
    var it = std.mem.splitScalar(u8, target[query_start..], '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

/// Finds and percent-decodes `key`'s value from a request target's query
/// string. Caller owns the result.
pub fn extractQueryParam(gpa: Allocator, target: []const u8, key: []const u8) !?[]u8 {
    const raw = findRawQueryParam(target, key) orelse return null;
    // percentDecodeInPlace shrinks in place and returns a shorter view of
    // the same buffer -- that view can't be freed on its own (its length
    // no longer matches the original allocation), so it's duped into a
    // correctly-sized allocation before the scratch buffer is freed.
    const scratch = try gpa.dupe(u8, raw);
    defer gpa.free(scratch);
    const decoded = std.Uri.percentDecodeInPlace(scratch);
    return try gpa.dupe(u8, decoded);
}

// ---- Token cache (access token + expiry only; refresh token lives in the keyring) ----

pub const CachedToken = struct {
    access_token: []u8,
    expires_at: i64,

    pub fn deinit(self: *CachedToken, gpa: Allocator) void {
        gpa.free(self.access_token);
        self.* = undefined;
    }
};

const max_token_cache_size = 8 * 1024;
const token_cache_file = "token.json";

pub fn loadCachedToken(gpa: Allocator, io: Io, dir: Dir) ?CachedToken {
    var buf: [max_token_cache_size + 1]u8 = undefined;
    const data = cache.readBounded(dir, io, token_cache_file, &buf) catch return null;

    const Shape = struct { access_token: []const u8, expires_at: i64 };
    const parsed = std.json.parseFromSlice(Shape, gpa, data, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    const access_token = gpa.dupe(u8, parsed.value.access_token) catch return null;
    return .{ .access_token = access_token, .expires_at = parsed.value.expires_at };
}

pub fn saveCachedToken(gpa: Allocator, io: Io, dir: Dir, access_token: []const u8, expires_at: i64) !void {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.json.Stringify.value(.{ .access_token = access_token, .expires_at = expires_at }, .{}, &out.writer);
    try cache.atomicWrite(dir, io, token_cache_file, out.written(), cache.private_file_permissions);
}

/// Access tokens are refreshed this many seconds before their reported
/// expiry, so a token that's technically still valid when `status` reads
/// it doesn't expire mid-request.
pub const expiry_safety_margin_s: i64 = 60;

pub fn currentUnixTime(io: Io) i64 {
    return Io.Timestamp.now(io, .real).toSeconds();
}

// ---- Token exchange / refresh (live network calls) ----

pub const TokenResponse = struct {
    access_token: []u8,
    /// Present on the initial exchange (we always request
    /// access_type=offline&prompt=consent, which Google documents as
    /// guaranteeing one); absent on a refresh-token grant, which doesn't
    /// return a new one.
    refresh_token: ?[]u8,
    expires_in: i64,

    pub fn deinit(self: *TokenResponse, gpa: Allocator) void {
        gpa.free(self.access_token);
        if (self.refresh_token) |rt| gpa.free(rt);
        self.* = undefined;
    }
};

fn appendFormParam(gpa: Allocator, list: *std.ArrayList(u8), first: bool, key: []const u8, value: []const u8) !void {
    if (!first) try list.append(gpa, '&');
    try list.appendSlice(gpa, key);
    try list.append(gpa, '=');
    const encoded = try percentEncode(gpa, value);
    defer gpa.free(encoded);
    try list.appendSlice(gpa, encoded);
}

pub fn parseTokenResponse(gpa: Allocator, body: []const u8) !TokenResponse {
    const Shape = struct {
        access_token: []const u8,
        refresh_token: ?[]const u8 = null,
        expires_in: i64,
    };
    const parsed = try std.json.parseFromSlice(Shape, gpa, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return .{
        .access_token = try gpa.dupe(u8, parsed.value.access_token),
        .refresh_token = if (parsed.value.refresh_token) |rt| try gpa.dupe(u8, rt) else null,
        .expires_in = parsed.value.expires_in,
    };
}

fn postForm(gpa: Allocator, http_client: *std.http.Client, url: []const u8, body: []const u8) ![]u8 {
    var response_body: Io.Writer.Allocating = .init(gpa);
    errdefer response_body.deinit();
    const result = try http_client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }},
        .response_writer = &response_body.writer,
    });
    if (result.status != .ok) {
        std.debug.print("waybar-gmail: oauth token endpoint returned {d}\n", .{@intFromEnum(result.status)});
        return error.TokenExchangeFailed;
    }
    return response_body.toOwnedSlice();
}

pub fn exchangeCodeForTokens(
    gpa: Allocator,
    http_client: *std.http.Client,
    creds: ClientCredentials,
    code: []const u8,
    redirect_uri: []const u8,
    code_verifier: []const u8,
) !TokenResponse {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try appendFormParam(gpa, &body, true, "code", code);
    try appendFormParam(gpa, &body, false, "client_id", creds.client_id);
    try appendFormParam(gpa, &body, false, "client_secret", creds.client_secret);
    try appendFormParam(gpa, &body, false, "redirect_uri", redirect_uri);
    try appendFormParam(gpa, &body, false, "grant_type", "authorization_code");
    try appendFormParam(gpa, &body, false, "code_verifier", code_verifier);

    const resp_body = try postForm(gpa, http_client, creds.token_uri, body.items);
    defer gpa.free(resp_body);
    return parseTokenResponse(gpa, resp_body);
}

pub fn refreshAccessToken(
    gpa: Allocator,
    http_client: *std.http.Client,
    creds: ClientCredentials,
    refresh_token: []const u8,
) !TokenResponse {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try appendFormParam(gpa, &body, true, "client_id", creds.client_id);
    try appendFormParam(gpa, &body, false, "client_secret", creds.client_secret);
    try appendFormParam(gpa, &body, false, "refresh_token", refresh_token);
    try appendFormParam(gpa, &body, false, "grant_type", "refresh_token");

    const resp_body = try postForm(gpa, http_client, creds.token_uri, body.items);
    defer gpa.free(resp_body);
    return parseTokenResponse(gpa, resp_body);
}

/// Returns a valid access token, refreshing it if necessary. Returns
/// `error.NotAuthenticated` if `auth` has never been run successfully --
/// callers (status.zig) map that to the "unauthenticated" waybar class.
pub fn getValidAccessToken(
    gpa: Allocator,
    io: Io,
    http_client: *std.http.Client,
    creds: ClientCredentials,
    state_dir: Dir,
) ![]u8 {
    const now = currentUnixTime(io);
    if (loadCachedToken(gpa, io, state_dir)) |cached| {
        var c = cached;
        if (c.expires_at - expiry_safety_margin_s > now) return c.access_token;
        c.deinit(gpa);
    }

    const refresh_token = (try secrets.lookup(gpa, io, secret_service, secret_account)) orelse
        return error.NotAuthenticated;
    defer gpa.free(refresh_token);

    var tokens = try refreshAccessToken(gpa, http_client, creds, refresh_token);
    defer tokens.deinit(gpa);

    try saveCachedToken(gpa, io, state_dir, tokens.access_token, now + tokens.expires_in);
    return try gpa.dupe(u8, tokens.access_token);
}

// ---- Interactive loopback + PKCE consent flow (the `auth` subcommand) ----

/// Runs the full installed-app loopback flow: binds an ephemeral local
/// port, opens the consent page in the browser, blocks waiting for the
/// single redirect back, exchanges the code for tokens, stores the
/// refresh token in the keyring, and caches the initial access token.
///
/// This blocks on `accept()` with no internal timeout -- for the real
/// `auth` subcommand that's the right UX (wait for the user, however long
/// that takes). The opportunistic attempt during unattended setup bounds
/// this from the *outside* instead, via the shell `timeout` command, which
/// needs no complexity here and works identically for both callers.
pub fn runConsentFlow(gpa: Allocator, io: Io, http_client: *std.http.Client, creds: ClientCredentials, state_dir: Dir) !void {
    var verifier_buf: [43]u8 = undefined;
    const verifier = generateCodeVerifier(io, &verifier_buf);
    var challenge_buf: [43]u8 = undefined;
    const challenge = computeCodeChallenge(verifier, &challenge_buf);
    var state_buf: [43]u8 = undefined;
    const state = generateCodeVerifier(io, &state_buf); // any random URL-safe string works equally well as CSRF state

    var addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    const port = server.socket.address.getPort();

    var redirect_buf: [32]u8 = undefined;
    const redirect_uri = try std.fmt.bufPrint(&redirect_buf, "http://localhost:{d}", .{port});

    const auth_url = try buildAuthorizationUrl(gpa, creds.auth_uri, creds.client_id, redirect_uri, challenge, state);
    defer gpa.free(auth_url);

    std.debug.print("waybar-gmail: open this URL to authorize (or it should open automatically):\n{s}\n", .{auth_url});
    openInBrowser(io, auth_url) catch |err| {
        std.debug.print("waybar-gmail: couldn't launch a browser automatically ({t}); open the URL above manually\n", .{err});
    };

    var stream = try server.accept(io);
    defer stream.close(io);

    var read_buf: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buf);
    const request_line = stream_reader.interface.takeDelimiterExclusive('\n') catch {
        try respondHtml(io, &stream, "Malformed request. You can close this tab.");
        return error.MalformedCallback;
    };
    const target = extractRequestTarget(std.mem.trimEnd(u8, request_line, "\r")) orelse {
        try respondHtml(io, &stream, "Malformed request. You can close this tab.");
        return error.MalformedCallback;
    };

    const got_state = try extractQueryParam(gpa, target, "state");
    defer if (got_state) |s| gpa.free(s);
    if (got_state == null or !std.mem.eql(u8, got_state.?, state)) {
        try respondHtml(io, &stream, "State mismatch -- possible CSRF. You can close this tab.");
        return error.StateMismatch;
    }

    const code = (try extractQueryParam(gpa, target, "code")) orelse {
        try respondHtml(io, &stream, "No authorization code received. You can close this tab.");
        return error.MissingCode;
    };
    defer gpa.free(code);

    var tokens = exchangeCodeForTokens(gpa, http_client, creds, code, redirect_uri, verifier) catch |err| {
        try respondHtml(io, &stream, "Token exchange failed. You can close this tab.");
        return err;
    };
    defer tokens.deinit(gpa);

    try respondHtml(io, &stream, "waybar-gmail is connected. You can close this tab.");

    const refresh_token = tokens.refresh_token orelse return error.NoRefreshToken;
    try secrets.store(io, secret_service, secret_account, "waybar-gmail Gmail refresh token", refresh_token);

    const now = currentUnixTime(io);
    try saveCachedToken(gpa, io, state_dir, tokens.access_token, now + tokens.expires_in);
}

fn respondHtml(io: Io, stream: *Io.net.Stream, message: []const u8) !void {
    var write_buf: [1024]u8 = undefined;
    var writer = stream.writer(io, &write_buf);
    writer.interface.print(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n" ++
            "<!doctype html><html><body><p>{s}</p></body></html>",
        .{message},
    ) catch return;
    writer.interface.flush() catch {};
}

fn openInBrowser(io: Io, url: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "xdg-open", url },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try child.wait(io);
}

// ---- tests ----

const testing = std.testing;

test "loadClientCredentials parses the installed-app shape" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "client_secret.json",
        .data =
        \\{"installed":{
        \\  "client_id":"123-abc.apps.googleusercontent.com",
        \\  "client_secret":"GOCSPX-fake",
        \\  "auth_uri":"https://accounts.google.com/o/oauth2/auth",
        \\  "token_uri":"https://oauth2.googleapis.com/token",
        \\  "redirect_uris":["http://localhost"]
        \\}}
        ,
    });

    var creds = try loadClientCredentials(testing.allocator, testing.io, tmp.dir, "client_secret.json");
    defer creds.deinit(testing.allocator);

    try testing.expectEqualStrings("123-abc.apps.googleusercontent.com", creds.client_id);
    try testing.expectEqualStrings("GOCSPX-fake", creds.client_secret);
    try testing.expectEqualStrings("https://accounts.google.com/o/oauth2/auth", creds.auth_uri);
    try testing.expectEqualStrings("https://oauth2.googleapis.com/token", creds.token_uri);
}

test "generateCodeVerifier produces a 43-character URL-safe string" {
    var buf: [43]u8 = undefined;
    const verifier = generateCodeVerifier(testing.io, &buf);
    try testing.expectEqual(@as(usize, 43), verifier.len);
    for (verifier) |c| {
        const ok = switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => true,
            else => false,
        };
        try testing.expect(ok);
    }
}

test "generateCodeVerifier is not the same twice" {
    var buf1: [43]u8 = undefined;
    var buf2: [43]u8 = undefined;
    const v1 = generateCodeVerifier(testing.io, &buf1);
    const v2 = generateCodeVerifier(testing.io, &buf2);
    try testing.expect(!std.mem.eql(u8, v1, v2));
}

test "computeCodeChallenge matches a known RFC 7636 appendix B test vector" {
    // RFC 7636 Appendix B's example verifier/challenge pair.
    const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    var buf: [43]u8 = undefined;
    const challenge = computeCodeChallenge(verifier, &buf);
    try testing.expectEqualStrings("E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", challenge);
}

test "percentEncode leaves unreserved characters alone" {
    const got = try percentEncode(testing.allocator, "abcXYZ019-._~");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("abcXYZ019-._~", got);
}

test "percentEncode escapes a redirect URI" {
    const got = try percentEncode(testing.allocator, "http://localhost:41234");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("http%3A%2F%2Flocalhost%3A41234", got);
}

test "buildAuthorizationUrl includes all required PKCE and OAuth params" {
    const url = try buildAuthorizationUrl(
        testing.allocator,
        "https://accounts.google.com/o/oauth2/auth",
        "my-client-id",
        "http://localhost:41234",
        "abc123challenge",
        "somestate",
    );
    defer testing.allocator.free(url);

    try testing.expect(std.mem.startsWith(u8, url, "https://accounts.google.com/o/oauth2/auth?"));
    try testing.expect(std.mem.indexOf(u8, url, "response_type=code") != null);
    try testing.expect(std.mem.indexOf(u8, url, "client_id=my-client-id") != null);
    try testing.expect(std.mem.indexOf(u8, url, "redirect_uri=http%3A%2F%2Flocalhost%3A41234") != null);
    try testing.expect(std.mem.indexOf(u8, url, "code_challenge=abc123challenge") != null);
    try testing.expect(std.mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try testing.expect(std.mem.indexOf(u8, url, "access_type=offline") != null);
    try testing.expect(std.mem.indexOf(u8, url, "state=somestate") != null);
}

test "extractRequestTarget pulls the target out of a request line" {
    try testing.expectEqualStrings(
        "/?code=abc&state=xyz",
        extractRequestTarget("GET /?code=abc&state=xyz HTTP/1.1").?,
    );
}

test "extractRequestTarget returns null for a malformed line" {
    try testing.expect(extractRequestTarget("garbage") == null);
}

test "extractQueryParam finds and decodes the code parameter" {
    const got = try extractQueryParam(testing.allocator, "/?code=4%2F0AX4Xf&state=xyz", "code");
    defer if (got) |g| testing.allocator.free(g);
    try testing.expectEqualStrings("4/0AX4Xf", got.?);
}

test "extractQueryParam returns null when the key is absent" {
    const got = try extractQueryParam(testing.allocator, "/?state=xyz", "code");
    try testing.expect(got == null);
}

test "extractQueryParam returns null for a target with no query string" {
    const got = try extractQueryParam(testing.allocator, "/favicon.ico", "code");
    try testing.expect(got == null);
}

test "saveCachedToken then loadCachedToken round-trips" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try saveCachedToken(testing.allocator, testing.io, tmp.dir, "ya29.fake-access-token", 1234567890);

    var loaded = loadCachedToken(testing.allocator, testing.io, tmp.dir).?;
    defer loaded.deinit(testing.allocator);
    try testing.expectEqualStrings("ya29.fake-access-token", loaded.access_token);
    try testing.expectEqual(@as(i64, 1234567890), loaded.expires_at);
}

test "loadCachedToken returns null when no cache file exists" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expect(loadCachedToken(testing.allocator, testing.io, tmp.dir) == null);
}

test "loadCachedToken returns null on malformed cache content" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = token_cache_file, .data = "not json" });
    try testing.expect(loadCachedToken(testing.allocator, testing.io, tmp.dir) == null);
}

test "parseTokenResponse parses the initial exchange shape (with refresh_token)" {
    var tokens = try parseTokenResponse(testing.allocator,
        \\{"access_token":"ya29.abc","refresh_token":"1//09xyz","expires_in":3599,"token_type":"Bearer","scope":"https://www.googleapis.com/auth/gmail.modify"}
    );
    defer tokens.deinit(testing.allocator);

    try testing.expectEqualStrings("ya29.abc", tokens.access_token);
    try testing.expectEqualStrings("1//09xyz", tokens.refresh_token.?);
    try testing.expectEqual(@as(i64, 3599), tokens.expires_in);
}

test "parseTokenResponse parses the refresh-grant shape (no refresh_token)" {
    var tokens = try parseTokenResponse(testing.allocator,
        \\{"access_token":"ya29.def","expires_in":3599,"token_type":"Bearer"}
    );
    defer tokens.deinit(testing.allocator);

    try testing.expectEqualStrings("ya29.def", tokens.access_token);
    try testing.expect(tokens.refresh_token == null);
}

test "currentUnixTime returns a plausible recent timestamp" {
    const t = currentUnixTime(testing.io);
    // Sanity bound, not a real clock check: some time after this project
    // existing (2026-09-01) and comfortably before it stops existing.
    try testing.expect(t > 1788300000 and t < 4102444800);
}
