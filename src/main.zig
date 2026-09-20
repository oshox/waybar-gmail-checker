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

comptime {
    _ = mime;
    _ = cache;
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
        // Implemented in later milestones (M2: auth/gmail client, M3:
        // status, M4: click, M5: popup/action, M6: open). Each currently
        // reports "not yet implemented" rather than doing nothing silently.
        .status, .click, .popup, .action, .auth, .open => {
            std.debug.print("waybar-gmail: '{s}' is not implemented yet\n", .{sub_arg});
            return 1;
        },
    }
}
