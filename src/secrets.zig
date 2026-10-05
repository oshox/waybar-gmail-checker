//! Wraps `secret-tool` (libsecret) as a subprocess for storing and
//! retrieving the OAuth refresh token. Nothing in this project links
//! libsecret directly -- keeping the CLI binary's dependency footprint at
//! zero is the whole point of the static-musl build (see
//! docs/zig-016-api-notes.md).
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Error = error{
    SecretToolFailed,
} || std.process.SpawnError || std.process.Child.WaitError || Allocator.Error;

/// Stores `secret` in the user's keyring, tagged with `service`/`account`
/// attributes (overwriting any existing secret with the same attributes).
pub fn store(io: Io, service: []const u8, account: []const u8, label: []const u8, secret: []const u8) Error!void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "secret-tool", "store", "--label", label, "service", service, "account", account },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    // From here on the child exists, so stdin must be closed and the child
    // reaped on every path -- a failed write used to return straight out,
    // leaking the pipe and leaving a zombie.
    const wrote = blk: {
        const stdin = child.stdin.?;
        defer {
            stdin.close(io);
            child.stdin = null;
        }
        stdin.writeStreamingAll(io, secret) catch break :blk false;
        break :blk true;
    };

    const term = try child.wait(io);
    if (!wrote) return error.SecretToolFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.SecretToolFailed,
        else => return error.SecretToolFailed,
    }
}

/// Looks up the secret for `service`/`account`. Returns `null` if no
/// matching secret exists (not found is a normal, expected outcome --
/// callers use it to distinguish "never authenticated" from a real
/// failure). Caller owns the returned slice.
pub fn lookup(gpa: Allocator, io: Io, service: []const u8, account: []const u8) Error!?[]u8 {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "secret-tool", "lookup", "service", service, "account", account },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    const stdout = child.stdout.?;

    // Refresh tokens are at most a few hundred bytes; this is generous
    // headroom, not a real limit we expect to hit. It holds the secret, so
    // it's wiped on the way out (the caller gets its own heap copy).
    var buf: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);

    // The pipe is closed and the child reaped whether or not the read
    // worked; a failed read used to return before either, leaking the fd
    // and leaving a zombie.
    const read_len: ?usize = blk: {
        defer {
            stdout.close(io);
            child.stdout = null;
        }
        var reader = stdout.reader(io, &.{});
        break :blk reader.interface.readSliceShort(&buf) catch null;
    };

    const term = try child.wait(io);
    const n = read_len orelse return error.SecretToolFailed;
    const found = switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!found) return null;

    const trimmed = std.mem.trimEnd(u8, buf[0..n], "\n");
    if (trimmed.len == 0) return null;
    return try gpa.dupe(u8, trimmed);
}

/// Removes the secret for `service`/`account`, if any. Not finding one to
/// remove is not an error.
pub fn clear(io: Io, service: []const u8, account: []const u8) Error!void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "secret-tool", "clear", "service", service, "account", account },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    // secret-tool clear's exit code isn't meaningfully distinct for
    // "nothing to clear" vs other conditions across versions; either way
    // there's nothing actionable left to do here.
    _ = try child.wait(io);
}

// ---- tests ----
//
// These exercise the real `secret-tool` binary (present and confirmed
// working in this environment) against a throwaway service/account name,
// cleaned up in each test, so they never touch real waybar-gmail secrets.

const testing = std.testing;

const test_service = "waybar-gmail-test-suite";

test "store then lookup round-trips the secret" {
    const account = "roundtrip@example.com";
    defer clear(testing.io, test_service, account) catch {};

    try store(testing.io, test_service, account, "waybar-gmail test", "s3cr3t-value");

    const got = try lookup(testing.allocator, testing.io, test_service, account);
    defer if (got) |g| testing.allocator.free(g);

    try testing.expect(got != null);
    try testing.expectEqualStrings("s3cr3t-value", got.?);
}

test "lookup returns null for an account that was never stored" {
    const account = "never-stored@example.com";
    defer clear(testing.io, test_service, account) catch {};

    const got = try lookup(testing.allocator, testing.io, test_service, account);
    try testing.expect(got == null);
}

test "store overwrites a previous secret for the same account" {
    const account = "overwrite@example.com";
    defer clear(testing.io, test_service, account) catch {};

    try store(testing.io, test_service, account, "waybar-gmail test", "first-value");
    try store(testing.io, test_service, account, "waybar-gmail test", "second-value");

    const got = try lookup(testing.allocator, testing.io, test_service, account);
    defer if (got) |g| testing.allocator.free(g);

    try testing.expectEqualStrings("second-value", got.?);
}

test "clear removes a stored secret" {
    const account = "clear-me@example.com";

    try store(testing.io, test_service, account, "waybar-gmail test", "temp-value");
    try clear(testing.io, test_service, account);

    const got = try lookup(testing.allocator, testing.io, test_service, account);
    try testing.expect(got == null);
}
