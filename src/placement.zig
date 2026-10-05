//! Where the popup goes, given where the pointer was when it was opened.
//!
//! Waybar doesn't tell `on-click` handlers where the module is, and a
//! Wayland client can't ask where another client drew something -- but at
//! click time the pointer is, by definition, on the module. popup.zig
//! briefly maps an invisible full-output surface to read the pointer's
//! position, then hands it to `compute` here.
//!
//! Kept free of any GTK dependency so the geometry is unit-testable (see
//! the tests at the bottom; popup.zig itself isn't reachable from `zig
//! build test`'s import graph).
const std = @import("std");

pub const Edge = enum { left, right, top, bottom };

/// Pointer position in output-local (logical) pixels, plus the output's
/// size, which is what lets `compute` tell which screen edge the bar is on.
pub const Pointer = struct {
    x: f64,
    y: f64,
    out_w: i32,
    out_h: i32,
};

pub const Layout = struct {
    /// The screen edge the bar sits on (the one nearest the pointer). The
    /// popup is anchored to it, so the compositor keeps the popup clear of
    /// the bar's exclusive zone rather than opening on top of the bar.
    bar_edge: Edge,
    /// The second anchored edge, perpendicular to `bar_edge`: top for a
    /// left/right bar, left for a top/bottom bar.
    cross_edge: Edge,
    /// Gap between the popup and the bar.
    bar_margin: i32,
    /// Offset along the bar, chosen so the popup lines up with the pointer
    /// and stays fully on screen.
    cross_margin: i32,
};

/// Gap left between the bar and the popup.
const bar_gap: i32 = 6;
/// How far above the pointer a popup on a vertical bar starts, so its
/// header (not its top edge) lines up with the icon that was clicked.
const header_offset: f64 = 20;

pub fn nearestEdge(p: Pointer) Edge {
    const w: f64 = @floatFromInt(p.out_w);
    const h: f64 = @floatFromInt(p.out_h);
    const candidates = [_]struct { edge: Edge, dist: f64 }{
        .{ .edge = .left, .dist = p.x },
        .{ .edge = .right, .dist = w - p.x },
        .{ .edge = .top, .dist = p.y },
        .{ .edge = .bottom, .dist = h - p.y },
    };
    var best = candidates[0];
    for (candidates[1..]) |cand| {
        if (cand.dist < best.dist) best = cand;
    }
    return best.edge;
}

pub fn compute(p: Pointer, popup_w: i32, popup_h: i32) Layout {
    const bar = nearestEdge(p);
    const vertical_bar = bar == .left or bar == .right;

    // Where along the bar the popup starts, then clamped so the whole popup
    // stays on screen. The upper bound is floored at 0 so a popup bigger
    // than the output pins to the origin instead of inverting the range.
    const wanted: f64 = if (vertical_bar) p.y - header_offset else p.x - @as(f64, @floatFromInt(popup_w)) / 2;
    const room: i32 = if (vertical_bar) p.out_h - popup_h else p.out_w - popup_w;
    const hi: f64 = @floatFromInt(@max(room, 0));
    const along = std.math.clamp(@floor(wanted), 0, hi);

    return .{
        .bar_edge = bar,
        .cross_edge = if (vertical_bar) .top else .left,
        .bar_margin = bar_gap,
        .cross_margin = @intFromFloat(along),
    };
}

// ---- tests ----

const testing = std.testing;

test "nearestEdge: a pointer on a left bar picks left" {
    try testing.expectEqual(Edge.left, nearestEdge(.{ .x = 19, .y = 400, .out_w = 1638, .out_h = 1024 }));
}

test "nearestEdge: right, top and bottom bars" {
    try testing.expectEqual(Edge.right, nearestEdge(.{ .x = 1620, .y = 400, .out_w = 1638, .out_h = 1024 }));
    try testing.expectEqual(Edge.top, nearestEdge(.{ .x = 800, .y = 12, .out_w = 1638, .out_h = 1024 }));
    try testing.expectEqual(Edge.bottom, nearestEdge(.{ .x = 800, .y = 1010, .out_w = 1638, .out_h = 1024 }));
}

test "compute: left bar anchors left+top and lines the header up with the pointer" {
    const l = compute(.{ .x = 19, .y = 400, .out_w = 1638, .out_h = 1024 }, 360, 300);
    try testing.expectEqual(Edge.left, l.bar_edge);
    try testing.expectEqual(Edge.top, l.cross_edge);
    try testing.expectEqual(@as(i32, 6), l.bar_margin);
    try testing.expectEqual(@as(i32, 380), l.cross_margin);
}

test "compute: a popup near the bottom of a vertical bar is pulled back on screen" {
    const l = compute(.{ .x = 19, .y = 1000, .out_w = 1638, .out_h = 1024 }, 360, 300);
    try testing.expectEqual(@as(i32, 724), l.cross_margin); // 1024 - 300
}

test "compute: a pointer near the top of a vertical bar clamps at 0, never negative" {
    const l = compute(.{ .x = 19, .y = 5, .out_w = 1638, .out_h = 1024 }, 360, 300);
    try testing.expectEqual(@as(i32, 0), l.cross_margin);
}

test "compute: top bar anchors top+left and centres the popup on the pointer" {
    const l = compute(.{ .x = 800, .y = 12, .out_w = 1638, .out_h = 1024 }, 360, 300);
    try testing.expectEqual(Edge.top, l.bar_edge);
    try testing.expectEqual(Edge.left, l.cross_edge);
    try testing.expectEqual(@as(i32, 620), l.cross_margin); // 800 - 360/2
}

test "compute: a top-bar popup near the right edge stays fully on screen" {
    // y=3 so the top edge (3px) is unambiguously nearer than the right one (8px).
    const l = compute(.{ .x = 1630, .y = 3, .out_w = 1638, .out_h = 1024 }, 360, 300);
    try testing.expectEqual(Edge.top, l.bar_edge);
    try testing.expectEqual(@as(i32, 1278), l.cross_margin); // 1638 - 360
}

test "compute: a popup taller than the output pins to 0 instead of going negative" {
    const l = compute(.{ .x = 19, .y = 400, .out_w = 1638, .out_h = 200 }, 360, 500);
    try testing.expectEqual(@as(i32, 0), l.cross_margin);
}
