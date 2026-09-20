//! waybar-gmail: the non-GTK CLI. Built fully static (musl) because
//! `status` is the hot path -- waybar respawns it on every poll interval --
//! and every dynamic-linking dependency here is a cost paid on every single
//! run. GTK lives entirely in the separate `waybar-gmail-popup` binary
//! (src/popup_main.zig), spawned only on click.
const std = @import("std");

// Pure-logic modules land here as they're built out (M1: mime, cache).
// Referencing them from this root module is what makes `zig build test`
// exercise their `test` blocks.
const mime = @import("mime.zig");
const cache = @import("cache.zig");
const http = @import("http.zig");
const config = @import("config.zig");
const secrets = @import("secrets.zig");
const gmail = @import("gmail.zig");
const oauth = @import("oauth.zig");
const status = @import("status.zig");

comptime {
    _ = mime;
    _ = cache;
    _ = http;
    _ = config;
    _ = secrets;
    _ = gmail;
    _ = oauth;
    _ = status;
}

const Subcommand = enum {
    status,
    click,
    popup,
    action,
    auth,
    open,
};

const usage =
    \\usage: waybar-gmail <subcommand> [args...]
    \\
    \\subcommands:
    \\  status              print the waybar JSON status line
    \\  click               single/double-click dispatcher (waybar on-click target)
    \\  popup               open the message list popup
    \\  action <cmd> <id>   mark-read | archive | trash a message
    \\  auth                run the OAuth consent flow
    \\  open [id]           open the inbox, or one message, in the browser
    \\
;

/// Zig 0.16's `std.process.Init` main-function convention: the runtime
/// parses argv/environ and hands us a ready `Io` (see
/// docs/zig-016-api-notes.md), a `gpa` that's leak-checked automatically in
/// debug builds -- directly satisfying M7's "every subcommand runs under a
/// leak-detecting allocator" requirement with no extra setup -- and an
/// arena for anything that should just live for the process's lifetime.
/// M2 onward thread `init.io` and `init.gpa` down into the real subcommand
/// implementations; this skeleton doesn't need them yet.
pub fn main(init: std.process.Init) u8 {
    var arg_it = init.minimal.args.iterate();
    defer arg_it.deinit();
    _ = arg_it.next(); // argv[0]

    const sub_arg = arg_it.next() orelse {
        std.debug.print("{s}", .{usage});
        return 2;
    };

    const sub = std.meta.stringToEnum(Subcommand, sub_arg) orelse {
        std.debug.print("waybar-gmail: unknown subcommand '{s}'\n{s}", .{ sub_arg, usage });
        return 2;
    };

    switch (sub) {
        .auth => return cmdAuth(init),
        .status => return status.run(init),
        // Implemented in later milestones (M4: click, M5: popup/action,
        // M6: open). Each currently reports "not yet implemented" rather
        // than doing nothing silently.
        .click, .popup, .action, .open => {
            std.debug.print("waybar-gmail: '{s}' is not implemented yet\n", .{sub_arg});
            return 1;
        },
    }
}

fn cmdAuth(init: std.process.Init) u8 {
    const gpa = init.gpa;
    const io = init.io;

    var dirs = config.openDirs(gpa, io, init.environ_map) catch |err| {
        std.debug.print("waybar-gmail: can't set up config/state directories: {t}\n", .{err});
        return 1;
    };
    defer dirs.deinit(gpa, io);

    var creds = oauth.loadClientCredentials(gpa, io, dirs.config_dir, "client_secret.json") catch |err| {
        std.debug.print(
            "waybar-gmail: can't read client_secret.json from {s}: {t}\n" ++
                "See the README for how to create a Google Cloud OAuth client and place it there.\n",
            .{ dirs.config_path, err },
        );
        return 1;
    };
    defer creds.deinit(gpa);

    var http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer http_client.deinit();

    oauth.runConsentFlow(gpa, io, &http_client, creds, dirs.state_dir) catch |err| {
        std.debug.print("waybar-gmail: authentication failed: {t}\n", .{err});
        return 1;
    };

    std.debug.print("waybar-gmail: authenticated successfully.\n", .{});
    return 0;
}
