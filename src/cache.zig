//! Generic on-disk state primitives shared by every subcommand: atomic
//! writes, size-bounded reads, and the app's runtime directory. Callers
//! (oauth.zig, gmail.zig, status.zig, click.zig) own their own file names
//! and JSON schemas; this module only owns the mechanism.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

/// Mode for files containing secrets or otherwise private state (tokens,
/// cached message content): owner read/write only.
pub const private_file_permissions: Dir.Permissions = .fromMode(0o600);

/// Mode for the app's own directories under $XDG_RUNTIME_DIR and
/// ~/.config: owner-only traversal.
pub const private_dir_permissions: Dir.Permissions = .fromMode(0o700);

/// Pure computation of the app's runtime state directory, given the value
/// of $XDG_RUNTIME_DIR (or null if unset). Kept separate from environment
/// access so it's testable without touching the real environment.
pub fn runtimeDirPath(gpa: Allocator, xdg_runtime_dir: ?[]const u8) error{ OutOfMemory, NoRuntimeDir }![]u8 {
    const base = xdg_runtime_dir orelse return error.NoRuntimeDir;
    if (base.len == 0) return error.NoRuntimeDir;
    return Dir.path.join(gpa, &.{ base, "waybar-gmail" }) catch return error.OutOfMemory;
}

/// Writes `data` to `sub_path` inside `dir` atomically: write to a uniquely
/// named temporary file in the same directory, then rename over the
/// target. A reader can never observe a partially written file -- it sees
/// either the old contents or the fully new ones, never a mix.
///
/// `sub_path` must be a bare filename (no directory separators); every
/// current caller writes a single named file into a directory it already
/// owns.
///
/// No fsync: every current caller writes into $XDG_RUNTIME_DIR, which is
/// tmpfs -- there is nothing durable to flush, and the atomic rename alone
/// prevents torn reads. If this is ever pointed at non-volatile storage,
/// add `file.sync(io)` before the rename.
pub fn atomicWrite(
    dir: Dir,
    io: Io,
    sub_path: []const u8,
    data: []const u8,
    permissions: Dir.Permissions,
) !void {
    var random_bytes: [8]u8 = undefined;
    io.random(&random_bytes);
    const suffix: u64 = @bitCast(random_bytes);
    return atomicWriteWithSuffix(dir, io, sub_path, data, permissions, suffix);
}

/// Builds the temp-file name `atomicWrite` uses: `sub_path` plus a random
/// 64-bit suffix, so two concurrent writers (e.g. a `status` poll and a
/// `click` action racing) can't collide.
fn tmpName(buf: []u8, sub_path: []const u8, suffix: u64) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.tmp.{x}", .{ sub_path, suffix }) catch error.NameTooLong;
}

/// `atomicWrite` with the random suffix broken out as a parameter, so tests
/// can predict the temp file's exact name instead of listing the directory
/// to find it (`Dir.iterate`/`next(io)` hits a confirmed upstream bug in
/// Zig 0.16.0's `std.Io.Threaded` on Linux -- `dirReadLinux` panics with
/// "programmer bug caused syscall error: BADF" even on a freshly created,
/// otherwise-untouched directory; see docs/zig-016-api-notes.md. Avoided
/// entirely here rather than worked around, since nothing in this module
/// actually needs directory iteration).
fn atomicWriteWithSuffix(
    dir: Dir,
    io: Io,
    sub_path: []const u8,
    data: []const u8,
    permissions: Dir.Permissions,
    suffix: u64,
) !void {
    std.debug.assert(std.mem.indexOfScalar(u8, sub_path, '/') == null);

    var tmp_name_buf: [Dir.max_name_bytes]u8 = undefined;
    const tmp_name = try tmpName(&tmp_name_buf, sub_path, suffix);

    errdefer dir.deleteFile(io, tmp_name) catch {};
    {
        var file = try dir.createFile(io, tmp_name, .{
            .exclusive = true,
            .permissions = permissions,
        });
        errdefer file.close(io);
        try file.writeStreamingAll(io, data);
        file.close(io);
    }
    try dir.rename(tmp_name, dir, sub_path, io);
}

pub const ReadBoundedError = Dir.ReadFileError || error{FileTooLarge};

/// Reads `sub_path` from `dir` with truncation unambiguously detected: pass
/// a `buffer` at least one byte larger than the largest legitimate file
/// this caller expects. If the file fills the buffer exactly, that's
/// reported as `error.FileTooLarge` rather than silently returning a
/// truncated result.
pub fn readBounded(dir: Dir, io: Io, sub_path: []const u8, buffer: []u8) ReadBoundedError![]u8 {
    const data = try dir.readFile(io, sub_path, buffer);
    if (data.len == buffer.len) return error.FileTooLarge;
    return data;
}

/// Opens (creating if necessary, with `private_dir_permissions`) the app's
/// runtime state directory.
pub fn openOrCreateAppDir(io: Io, path: []const u8) !Dir {
    return Dir.cwd().createDirPathOpen(io, path, .{
        .permissions = private_dir_permissions,
    });
}

// ---- tests ----

const testing = std.testing;

test "runtimeDirPath joins the base and appends waybar-gmail" {
    const got = try runtimeDirPath(testing.allocator, "/run/user/1000");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("/run/user/1000/waybar-gmail", got);
}

test "runtimeDirPath rejects a null XDG_RUNTIME_DIR" {
    try testing.expectError(error.NoRuntimeDir, runtimeDirPath(testing.allocator, null));
}

test "runtimeDirPath rejects an empty XDG_RUNTIME_DIR" {
    try testing.expectError(error.NoRuntimeDir, runtimeDirPath(testing.allocator, ""));
}

test "atomicWrite then readBounded round-trips the data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try atomicWrite(tmp.dir, testing.io, "state.json", "{\"unread\":3}", private_file_permissions);

    var buf: [64]u8 = undefined;
    const got = try readBounded(tmp.dir, testing.io, "state.json", &buf);
    try testing.expectEqualStrings("{\"unread\":3}", got);
}

test "atomicWrite overwrites an existing file completely (no leftover bytes)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try atomicWrite(tmp.dir, testing.io, "state.json", "a very long first value indeed", private_file_permissions);
    try atomicWrite(tmp.dir, testing.io, "state.json", "short", private_file_permissions);

    var buf: [64]u8 = undefined;
    const got = try readBounded(tmp.dir, testing.io, "state.json", &buf);
    try testing.expectEqualStrings("short", got);
}

test "atomicWrite leaves no temp file behind on success" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try atomicWriteWithSuffix(tmp.dir, testing.io, "state.json", "hello", private_file_permissions, 0xdeadbeef);

    // The predictable temp name from that exact suffix must be gone...
    var buf: [64]u8 = undefined;
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.readFile(testing.io, "state.json.tmp.deadbeef", &buf),
    );
    // ...and the real target must hold the written data.
    const got = try readBounded(tmp.dir, testing.io, "state.json", &buf);
    try testing.expectEqualStrings("hello", got);
}

test "tmpName produces the exact name atomicWrite's cleanup targets" {
    var buf: [64]u8 = undefined;
    const got = try tmpName(&buf, "token.json", 0x1a2b3c);
    try testing.expectEqualStrings("token.json.tmp.1a2b3c", got);
}

test "readBounded reports FileTooLarge instead of silently truncating" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try atomicWrite(tmp.dir, testing.io, "big.json", "0123456789", private_file_permissions);

    var buf: [10]u8 = undefined; // exactly the file's size: ambiguous, must error
    try testing.expectError(error.FileTooLarge, readBounded(tmp.dir, testing.io, "big.json", &buf));
}

test "readBounded on a nonexistent file returns FileNotFound" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [64]u8 = undefined;
    try testing.expectError(error.FileNotFound, readBounded(tmp.dir, testing.io, "missing.json", &buf));
}

test "openOrCreateAppDir creates a private, reusable directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_abs = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_abs);
    const app_dir_path = try Dir.path.join(testing.allocator, &.{ tmp_abs, "waybar-gmail" });
    defer testing.allocator.free(app_dir_path);

    var dir1 = try openOrCreateAppDir(testing.io, app_dir_path);
    defer dir1.close(testing.io);

    // Called fresh on every process start; reopening an already-created
    // directory must not fail.
    var dir2 = try openOrCreateAppDir(testing.io, app_dir_path);
    defer dir2.close(testing.io);
}
