//! waybar-gmail-popup: the GTK entry point, built as a separate native
//! glibc binary from waybar-gmail so the hot 60s-poll `status` path never
//! links GTK. See docs/zig-016-api-notes.md for why src/c.zig hand-
//! declares GTK/gtk-layer-shell bindings instead of using @cImport, and
//! src/popup.zig for the actual UI.
const std = @import("std");
const popup = @import("popup.zig");

pub fn main(init: std.process.Init) u8 {
    return popup.run(init);
}
