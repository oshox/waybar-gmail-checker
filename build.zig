const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // `waybar-gmail` is the hot path: waybar respawns it every ~60s all day
    // (see docs/audit.md once M7 lands). Fully static musl means zero
    // dynamic linking, zero ld.so cache lookups, and -- critically -- zero
    // GTK/pango/cairo anywhere near it. Target is fixed rather than routed
    // through `-Dtarget=`, because a static musl build is the point, not an
    // option.
    const cli_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = cli_target,
        .optimize = optimize,
    });
    const cli_exe = b.addExecutable(.{
        .name = "waybar-gmail",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    // `waybar-gmail-popup` is only ever spawned on click, so its dependency
    // footprint doesn't matter the way the CLI's does. Native glibc, links
    // system GTK3 + gtk-layer-shell. See docs/zig-016-api-notes.md for why
    // src/c.zig hand-declares these bindings instead of @cImport.
    const native_target = b.standardTargetOptions(.{});
    const popup_mod = b.createModule(.{
        .root_source_file = b.path("src/popup_main.zig"),
        .target = native_target,
        .optimize = optimize,
        .link_libc = true,
    });
    popup_mod.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .yes });
    popup_mod.linkSystemLibrary("gtk-layer-shell-0", .{ .use_pkg_config = .yes });
    const popup_exe = b.addExecutable(.{
        .name = "waybar-gmail-popup",
        .root_module = popup_mod,
    });
    b.installArtifact(popup_exe);

    // Unit tests run against a native Debug build of the CLI's module graph
    // (mime.zig, cache.zig, config.zig, click.zig, gmail.zig, ...) so safety
    // checks are on and there's no cross-compilation quirk in the loop.
    // GTK-only code (c.zig, popup.zig) isn't reachable from main.zig's
    // import graph, so it's untouched here; see src/popup_main.zig for that.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = native_target,
        .optimize = .Debug,
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // `zig build run -- <subcommand>` for quick manual invocation during
    // development.
    const run_cli = b.addRunArtifact(cli_exe);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cli.addArgs(args);
    const run_step = b.step("run", "Run waybar-gmail (pass subcommand after --)");
    run_step.dependOn(&run_cli.step);
}
