//! waybar-gmail-popup: the GTK entry point, built as a separate native
//! glibc binary from waybar-gmail so the hot 60s-poll `status` path never
//! links GTK. See docs/zig-016-api-notes.md for why src/c.zig (landing in
//! M5, along with the actual UI in popup.zig) hand-declares GTK/gtk-layer-
//! shell bindings instead of using @cImport.
const std = @import("std");

pub fn main(init: std.process.Init) u8 {
    _ = init;
    std.debug.print("waybar-gmail-popup: not implemented yet (lands in M5)\n", .{});
    return 1;
}
