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
const click = @import("click.zig");
const placement = @import("placement.zig");

comptime {
    _ = mime;
    _ = cache;
    _ = http;
    _ = config;
    _ = secrets;
    _ = gmail;
    _ = oauth;
    _ = status;
    _ = click;
    _ = placement;
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
        .click => return click.run(init),
        .popup => return cmdPopup(init),
        .action => return cmdAction(init, &arg_it),
        .open => return cmdOpen(init, &arg_it),
    }
}

/// `waybar-gmail open [id]`: opens the inbox, or one message/thread when an
/// id is given, in the browser. This is what the shipped waybar snippet
/// binds to right-click. The account index comes from config.json (see
/// config.account_index) so it opens the right one of several signed-in
/// Google accounts.
fn cmdOpen(init: std.process.Init, arg_it: *std.process.Args.Iterator) u8 {
    const gpa = init.gpa;
    const io = init.io;

    const id = arg_it.next();

    var dirs = config.openDirs(gpa, io, init.environ_map) catch |err| {
        std.debug.print("waybar-gmail open: can't set up directories: {t}\n", .{err});
        return 1;
    };
    defer dirs.deinit(gpa, io);
    const cfg = config.load(gpa, io, dirs.config_dir);

    var url_buf: [512]u8 = undefined;
    const url = (if (id) |thread_id|
        gmail.messageUrl(&url_buf, cfg.account_index, thread_id)
    else
        gmail.inboxUrl(&url_buf, cfg.account_index)) catch {
        std.debug.print("waybar-gmail open: that id is too long to be a message id\n", .{});
        return 1;
    };

    oauth.openInBrowser(io, url) catch |err| {
        std.debug.print("waybar-gmail open: couldn't launch a browser: {t}\n", .{err});
        return 1;
    };
    return 0;
}

/// `waybar-gmail popup` is a convenience alias for running the GTK binary
/// directly -- it execs into waybar-gmail-popup rather than spawning it,
/// so this (fully static, zero-GTK) binary never needs to link GTK just
/// to offer the alias. The real on-click path (click.zig) spawns
/// waybar-gmail-popup directly and doesn't go through this at all.
fn cmdPopup(init: std.process.Init) u8 {
    const err = std.process.replace(init.io, .{ .argv = &.{"waybar-gmail-popup"} });
    std.debug.print("waybar-gmail: couldn't exec waybar-gmail-popup: {t}\n", .{err});
    return 1;
}

const ActionKind = enum { @"mark-read", archive, trash };

const action_usage = "usage: waybar-gmail action <mark-read|archive|trash> <message-id>\n";

fn cmdAction(init: std.process.Init, arg_it: *std.process.Args.Iterator) u8 {
    const gpa = init.gpa;
    const io = init.io;

    const action_arg = arg_it.next() orelse {
        std.debug.print("{s}", .{action_usage});
        return 2;
    };
    const id = arg_it.next() orelse {
        std.debug.print("{s}", .{action_usage});
        return 2;
    };
    const kind = std.meta.stringToEnum(ActionKind, action_arg) orelse {
        std.debug.print("waybar-gmail: unknown action '{s}'\n{s}", .{ action_arg, action_usage });
        return 2;
    };

    var dirs = config.openDirs(gpa, io, init.environ_map) catch |err| {
        std.debug.print("waybar-gmail action: can't set up directories: {t}\n", .{err});
        return 1;
    };
    defer dirs.deinit(gpa, io);

    var creds = oauth.loadClientCredentials(gpa, io, dirs.config_dir, "client_secret.json") catch |err| {
        std.debug.print("waybar-gmail action: can't read client_secret.json: {t}\n", .{err});
        return 1;
    };
    defer creds.deinit(gpa);

    var oauth_http_client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer oauth_http_client.deinit();
    const access_token = oauth.getValidAccessToken(gpa, io, &oauth_http_client, creds, dirs.state_dir) catch |err| {
        std.debug.print("waybar-gmail action: not authenticated: {t}\n", .{err});
        return 1;
    };
    defer oauth.secureFree(gpa, access_token);

    var gmail_client = http.Client.initFromEnv(gpa, io, init.environ_map);
    defer gmail_client.deinit();

    const result = switch (kind) {
        .@"mark-read" => gmail.markRead(gpa, &gmail_client, access_token, id),
        .archive => gmail.archive(gpa, &gmail_client, access_token, id),
        .trash => gmail.trash(gpa, &gmail_client, access_token, id),
    };
    result catch |err| {
        std.debug.print("waybar-gmail action: {s} on {s} failed: {t}\n", .{ action_arg, id, err });
        return 1;
    };

    // Best-effort: nudge waybar to refresh the count immediately rather
    // than waiting for the next poll interval. Note this doesn't update
    // the structured message/tooltip cache the popup owns (src/popup.zig)
    // -- a CLI-invoked action is expected to be reconciled by the next
    // popup open or status poll, not to keep those caches live itself.
    // `-x`: match the process name exactly, so the signal doesn't also hit
    // (and terminate) an open waybar-gmail-popup or this process itself.
    _ = std.process.spawn(io, .{
        .argv = &.{ "pkill", "-RTMIN+9", "-x", "waybar" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch {};

    return 0;
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
