//! The GTK3 + gtk-layer-shell message-list popup: preview unread
//! messages, mark-read/archive/trash per message, click a row to open it
//! in Gmail. See src/c.zig for why the bindings are hand-declared rather
//! than @cImport'd, and docs/zig-016-api-notes.md for the probe that
//! proved the approach.
//!
//! Design notes:
//! - Paints from the structured message cache first (instant, no network
//!   on the critical path), then a `g_timeout_add` fires almost
//!   immediately after the window is shown to refresh from Gmail and
//!   rebuild the list -- the window is already mapped by the time that
//!   runs, so "instant open, then quietly correct" holds without needing
//!   threads.
//! - Every button/row click carries its own independently-allocated,
//!   independently-freed context (rather than one context shared across a
//!   row's several signal connections) -- more small allocations, but it
//!   sidesteps any "which connection owns freeing this" bookkeeping
//!   entirely. Freed via GClosureNotify tied to the connection's own
//!   lifetime, which GTK tears down when the row widget is destroyed.
//! - Actions are optimistic: the row is removed from the UI immediately,
//!   then the API call runs; on failure the whole list is re-rendered
//!   from the (unmodified) in-memory message list and the header shows
//!   the error, so nothing is silently lost.
//! - At most `max_visible_rows` rows are ever shown. The rest of the
//!   fetched messages are a buffer: removing a row immediately slides the
//!   next buffered message into the freed slot, so the popup keeps its
//!   height (and the pointer stays over it) while there's more to do.
//! - Placement: the popup opens next to the bar, lined up with the icon
//!   that was clicked. Neither waybar nor the compositor will tell us where
//!   that is, but the pointer is on it at click time -- see beginProbe.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const c = @import("c.zig");
const config = @import("config.zig");
const gmail = @import("gmail.zig");
const http = @import("http.zig");
const messages_cache = @import("messages_cache.zig");
const oauth = @import("oauth.zig");
const placement = @import("placement.zig");
const status = @import("status.zig");

/// The popup never shows more rows than this; further fetched messages wait
/// in `AppState.messages` until an action frees a slot.
const max_visible_rows = 5;

const popup_width: c.gint = 360;

/// Only used for the very first placement, before the real height is known
/// (see resizeToFitContentCb, which re-places with the measured height).
const initial_height_estimate: c.gint = 300;

/// A leave-notify within this long of a resize we triggered ourselves is
/// the compositor reacting to the surface changing size under a stationary
/// pointer, not the user moving away -- see onWindowLeave.
const resize_leave_grace_us: i64 = 400_000;

/// How long the popup lingers after such a leave before closing. Longer
/// than the normal 500ms hover-leave delay: the user has just clicked an
/// action and is likely about to move to the next one.
const post_resize_close_delay_ms: c.guint = 2000;

/// Wraps the shared cache entry with the one thing that's specific to
/// this GTK-linked binary: the row widget currently showing it (if any
/// -- absent right after loading the cache, before the list box is
/// built, and for buffered messages beyond `max_visible_rows`).
const CachedMessage = struct {
    data: messages_cache.Entry,
    row: ?*c.GtkWidget = null,
    /// An action on this message is in flight (its row is already gone but
    /// the API call hasn't returned): it must not be given a new row.
    pending: bool = false,

    fn deinit(self: *CachedMessage, gpa: Allocator) void {
        self.data.deinit(gpa);
    }
};

const AppState = struct {
    gpa: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    creds: oauth.ClientCredentials,
    config_dir: Dir,
    state_dir: Dir,
    access_token: []u8,
    /// config.json, read once at startup.
    cfg: config.Config,
    /// The inbox's real unread total, which can exceed what's listed
    /// (`messages` holds at most `cfg.max_messages`). Read from the cache the
    /// status poll writes, refreshed on a network refresh, and decremented
    /// as messages are removed. Null until known.
    unread_total: ?u32 = null,
    gtk_app: *c.GtkApplication,
    window: *c.GtkWindow,
    list_box: *c.GtkWidget,
    header_label: *c.GtkWidget,
    /// The invisible surface that reads the pointer position at startup
    /// (see beginProbe), and the fallback timer that gives up on it. Both
    /// are null once finishProbe has run.
    probe: ?*c.GtkWidget = null,
    probe_timer: ?c.guint = null,
    /// Repeating timer that nudges the pointer until the probe sees it
    /// (see nudgePointer), and how many times it has fired.
    probe_nudge_timer: ?c.guint = null,
    probe_nudges: u8 = 0,
    /// Raw pointer position the probe reported, before the output size is
    /// attached to it in finishProbe.
    probe_xy: ?[2]f64 = null,
    /// Where the pointer was at click time; null means placement failed and
    /// the popup is just centred.
    pointer: ?placement.Pointer = null,
    /// Last height handed to the compositor, so a relayout that didn't
    /// change anything doesn't trigger a pointless resize (and the stray
    /// leave-notify that comes with it).
    last_height: c.gint = 0,
    /// Leave-notify events before this monotonic time (microseconds) are
    /// the echo of our own resize -- see onWindowLeave.
    ignore_leave_until_us: i64 = 0,
    messages: std.ArrayList(CachedMessage) = .empty,
    /// Guards against closePopup running twice: GTK signals that can
    /// legitimately fire close to simultaneously (a focus-out arriving
    /// right as Escape is pressed, for instance) must not both try to
    /// destroy the same window -- the second gtk_widget_destroy would
    /// operate on an already-finalized widget, and AppState itself would
    /// be freed twice via the resulting double "destroy" signal.
    closing: bool = false,
    /// The pending close-after-hover-leaves timeout source, if one is
    /// currently scheduled -- null otherwise. Tracked so a re-entry can
    /// cancel it (see onWindowEnter) and so closePopup can cancel it on
    /// every OTHER close path (Escape, an action emptying the list):
    /// leaving it scheduled would fire 500ms later against an AppState
    /// that closePopup already freed.
    hover_close_timer: ?c.guint = null,
    /// The pending resizeToFitContentCb timeout source, if one is scheduled
    /// (see scheduleResize). Tracked for the same reason as
    /// `hover_close_timer`: an action that empties the list closes the
    /// popup, and a resize queued by an earlier action must not fire
    /// afterwards against the AppState closePopup freed.
    resize_timer: ?c.guint = null,

    fn deinit(self: *AppState) void {
        for (self.messages.items) |*m| m.deinit(self.gpa);
        self.messages.deinit(self.gpa);
        oauth.secureFree(self.gpa, self.access_token);
        self.creds.deinit(self.gpa);
        self.config_dir.close(self.io);
        self.state_dir.close(self.io);
        self.gpa.destroy(self);
    }
};

// ---- structured message cache (read: instant open; write: after every refresh/action) ----
//
// Both the cache file format and the fetch-from-Gmail logic live in
// messages_cache.zig, shared with status.zig's per-poll refresh (see its
// own doc comment) -- this file only adds the GTK-specific `row` field on
// top via CachedMessage.

fn loadMessagesCache(gpa: Allocator, io: Io, dir: Dir) ?std.ArrayList(CachedMessage) {
    var entries = messages_cache.load(gpa, io, dir) orelse return null;
    defer entries.deinit(gpa);

    var out: std.ArrayList(CachedMessage) = .empty;
    for (entries.items) |e| out.append(gpa, .{ .data = e }) catch break;
    return out;
}

fn persistCaches(app: *AppState) void {
    var entries: std.ArrayList(messages_cache.Entry) = .empty;
    defer entries.deinit(app.gpa);
    for (app.messages.items) |m| entries.append(app.gpa, m.data) catch {};

    messages_cache.save(app.gpa, app.io, app.state_dir, entries.items) catch |err| {
        std.debug.print("waybar-gmail-popup: couldn't save message cache: {t}\n", .{err});
    };

    const lines = messages_cache.buildTooltipLines(app.gpa, entries.items) catch |err| {
        std.debug.print("waybar-gmail-popup: couldn't build tooltip lines: {t}\n", .{err});
        return;
    };
    defer {
        for (lines) |l| app.gpa.free(l);
        app.gpa.free(lines);
    }
    status.saveTooltipCache(app.gpa, app.io, app.state_dir, lines, unreadTotal(app)) catch |err| {
        std.debug.print("waybar-gmail-popup: couldn't save tooltip cache: {t}\n", .{err});
    };
}

fn notifyWaybar(io: Io) void {
    // Unlike the fire-and-forget xdg-open/popup spawns elsewhere in this
    // project (safe because the *spawning* process there exits within
    // milliseconds, so init reparents and reaps the child almost
    // immediately), the popup is long-lived and calls this once per
    // action -- several unreaped children in one popup session would
    // accumulate as zombies until the popup itself finally exits. Wait on
    // it; pkill returns essentially instantly either way.
    //
    // `-x` (exact name) is load-bearing: without it "waybar" is a regex
    // matched against every process name, which includes this very
    // process ("waybar-gmail-popup"). SIGRTMIN+9 has no handler here, so its
    // default action -- terminate -- closed the popup after every single
    // action.
    var child = std.process.spawn(io, .{
        .argv = &.{ "pkill", "-RTMIN+9", "-x", "waybar" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}

// ---- fetching ----

/// Builds the whole updated message list off-screen, then swaps it in
/// with a single show_all in populateListFromMessages.
///
/// A per-row "add it, show it, pump the main loop" version of this was
/// tried instead, to make rows appear progressively rather than after
/// one long pause. Reverted: live testing showed only one row out of
/// eight ever got a real size allocation -- every other row (and its
/// buttons) came back 1x1px, still flagged "visible" but with no actual
/// area, which is why the action buttons disappeared. Manually pumping
/// gtk_main_iteration mid-layout, while gtk_scrolled_window's natural-
/// height propagation is also renegotiating on every single addition,
/// does not reliably reach a settled layout -- confirmed by walking the
/// widget tree with gtk_widget_get_allocated_height/width after each
/// pump. It's also the likely cause of the popup feeling slower rather
/// than faster: each addition was forcing a fresh, incomplete resize
/// negotiation instead of one clean layout pass at the end.
fn fetchMessages(app: *AppState) ![]CachedMessage {
    var client = http.Client.initFromEnv(app.gpa, app.io, app.environ_map);
    defer client.deinit();

    // Previews already in the list are reused (fetchFromApi only asks Gmail
    // about message ids it hasn't seen). The shallow copy is just so the
    // list of Entry values can be passed along; nothing in it is freed here.
    var known: std.ArrayList(messages_cache.Entry) = .empty;
    defer known.deinit(app.gpa);
    for (app.messages.items) |m| try known.append(app.gpa, m.data);

    const entries = try messages_cache.fetchFromApi(app.gpa, &client, app.access_token, app.cfg.max_messages, known.items);
    // Each entry's string data is moved (by value -- just the slice
    // pointers) into `out` below, so only the now-empty outer array
    // needs freeing here, not messages_cache.freeEntries.
    defer app.gpa.free(entries);

    var out: std.ArrayList(CachedMessage) = .empty;
    errdefer {
        for (out.items) |*m| m.deinit(app.gpa);
        out.deinit(app.gpa);
    }
    // ensureTotalCapacityPrecise + appendAssumeCapacity rather than a
    // plain append in the loop: the fallible allocation happens once,
    // up front, so there's no partial-transfer state to reason about if
    // it fails partway through -- either every entry moves into `out`,
    // or none do.
    try out.ensureTotalCapacityPrecise(app.gpa, entries.len);
    for (entries) |e| out.appendAssumeCapacity(.{ .data = e });
    return out.toOwnedSlice(app.gpa);
}

// ---- UI construction ----

fn setLabelBold(gpa: Allocator, label: *c.GtkLabel, text: []const u8) void {
    const escaped = status.escapePango(gpa, text) catch return;
    defer gpa.free(escaped);
    const markup = std.fmt.allocPrintSentinel(gpa, "<b>{s}</b>", .{escaped}, 0) catch return;
    defer gpa.free(markup);
    c.gtk_label_set_markup(label, markup);
}

fn setLabelDim(gpa: Allocator, label: *c.GtkLabel, text: []const u8) void {
    const escaped = status.escapePango(gpa, text) catch return;
    defer gpa.free(escaped);
    const markup = std.fmt.allocPrintSentinel(gpa, "<span alpha=\"70%\">{s}</span>", .{escaped}, 0) catch return;
    defer gpa.free(markup);
    c.gtk_label_set_markup(label, markup);
}

const ActionKind = enum { mark_read, archive, trash };

fn actionLabel(kind: ActionKind) [:0]const u8 {
    return switch (kind) {
        .mark_read => "Mark read",
        .archive => "Archive",
        .trash => "Delete",
    };
}

const ActionContext = struct {
    app: *AppState,
    message_id: []u8,
    kind: ActionKind,

    fn destroy(ptr: c.gpointer, _: ?*anyopaque) callconv(.c) void {
        const self: *ActionContext = @ptrCast(@alignCast(ptr.?));
        self.app.gpa.free(self.message_id);
        self.app.gpa.destroy(self);
    }
};

/// Owns the copies performActionDeferredCb needs once it actually runs.
/// Not the same as ActionContext: that one (and its message_id) belongs
/// to the button and is freed the moment the row is destroyed below, so
/// anything needed after that point has to be its own copy.
const PendingActionContext = struct {
    app: *AppState,
    message_id: []u8,
    kind: ActionKind,
};

fn performActionDeferredCb(user_data: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *PendingActionContext = @ptrCast(@alignCast(user_data.?));
    // performAction can close the popup (the last message was removed),
    // which frees the AppState `ctx.app` points at -- so the allocator has
    // to be read out before the call, not through `ctx.app` after it.
    const gpa = ctx.app.gpa;
    performAction(ctx.app, ctx.message_id, ctx.kind);
    gpa.free(ctx.message_id);
    gpa.destroy(ctx);
    return 0; // G_SOURCE_REMOVE: one-shot
}

fn onActionClicked(_: *c.GtkWidget, user_data: c.gpointer) callconv(.c) void {
    const ctx: *ActionContext = @ptrCast(@alignCast(user_data.?));
    const app = ctx.app;
    const kind = ctx.kind;
    const message_id_copy = app.gpa.dupe(u8, ctx.message_id) catch return;

    // Optimistic: remove from the UI immediately, before the (still
    // synchronous, still blocking) network call. Destroying the row
    // here isn't enough on its own for it to actually disappear from
    // the screen -- GTK doesn't repaint until control returns to the
    // main loop. Manually pumping the loop with gtk_main_iteration()
    // right here was tried and reverted: it corrupted layout elsewhere
    // in this file (see fetchMessages's doc comment) when used to force
    // newly-added widgets to render, so it isn't trusted for this
    // either. Deferring the actual network call to the next main-loop
    // iteration via g_timeout_add -- the same mechanism refreshTimeoutCb
    // already uses successfully -- lets GTK process the destroy's
    // repaint on its own, through a path already proven to work.
    if (findMessageIndex(app, ctx.message_id)) |idx| {
        const msg = &app.messages.items[idx];
        msg.pending = true;
        if (msg.row) |row| destroyRow(row);
        msg.row = null;
        // Slide the next buffered message (if any) into the freed slot
        // right away, so the list keeps its height and the buttons stay
        // under the pointer for the next click.
        fillVisibleRows(app);
    }

    const deferred = app.gpa.create(PendingActionContext) catch {
        app.gpa.free(message_id_copy);
        return;
    };
    deferred.* = .{ .app = app, .message_id = message_id_copy, .kind = kind };
    _ = c.g_timeout_add(1, performActionDeferredCb, deferred);
}

const OpenContext = struct {
    app: *AppState,
    thread_id: []u8,

    fn destroy(ptr: c.gpointer, _: ?*anyopaque) callconv(.c) void {
        const self: *OpenContext = @ptrCast(@alignCast(ptr.?));
        self.app.gpa.free(self.thread_id);
        self.app.gpa.destroy(self);
    }
};

fn onRowClicked(_: *c.GtkWidget, _: *c.GdkEvent, user_data: c.gpointer) callconv(.c) c.gboolean {
    const ctx: *OpenContext = @ptrCast(@alignCast(user_data.?));
    var buf: [512]u8 = undefined;
    const url = gmail.messageUrl(&buf, ctx.app.cfg.account_index, ctx.thread_id) catch return 0;
    oauth.openInBrowser(ctx.app.io, url) catch |err| {
        std.debug.print("waybar-gmail-popup: couldn't open message: {t}\n", .{err});
    };
    return 0; // GDK_EVENT_PROPAGATE
}

fn addActionButton(app: *AppState, button_row: *c.GtkBox, message_id: []const u8, kind: ActionKind) !void {
    const ctx = try app.gpa.create(ActionContext);
    errdefer app.gpa.destroy(ctx);
    ctx.* = .{ .app = app, .message_id = try app.gpa.dupe(u8, message_id), .kind = kind };
    errdefer app.gpa.free(ctx.message_id);

    const button = c.gtk_button_new_with_label(actionLabel(kind));
    _ = c.g_signal_connect_data(button, "clicked", @ptrCast(&onActionClicked), ctx, ActionContext.destroy, 0);
    const button_box: *c.GtkBox = @ptrCast(button_row);
    c.gtk_box_pack_start(button_box, button, 0, 0, 4);
}

/// Builds one row's whole widget subtree (not yet added to the list box).
fn buildRow(app: *AppState, msg: *const CachedMessage) !*c.GtkWidget {
    const root_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    c.gtk_widget_set_margin_start(root_widget, 10);
    c.gtk_widget_set_margin_end(root_widget, 10);
    c.gtk_widget_set_margin_top(root_widget, 6);
    c.gtk_widget_set_margin_bottom(root_widget, 6);
    const root: *c.GtkBox = @ptrCast(root_widget);

    // Clickable content: sender, subject, snippet.
    const event_box_widget = c.gtk_event_box_new();
    const content_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    const content: *c.GtkBox = @ptrCast(content_widget);

    const from_widget = c.gtk_label_new(null);
    const from_label: *c.GtkLabel = @ptrCast(from_widget);
    setLabelBold(app.gpa, from_label, msg.data.from);
    c.gtk_label_set_xalign(from_label, 0);
    c.gtk_label_set_ellipsize(from_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_box_pack_start(content, from_widget, 0, 0, 0);

    const subject_widget = c.gtk_label_new(null);
    const subject_label: *c.GtkLabel = @ptrCast(subject_widget);
    {
        const escaped = status.escapePango(app.gpa, msg.data.subject) catch msg.data.subject;
        defer if (escaped.ptr != msg.data.subject.ptr) app.gpa.free(escaped);
        const z = std.fmt.allocPrintSentinel(app.gpa, "{s}", .{escaped}, 0) catch null;
        if (z) |zz| {
            defer app.gpa.free(zz);
            c.gtk_label_set_markup(subject_label, zz);
        }
    }
    c.gtk_label_set_xalign(subject_label, 0);
    c.gtk_label_set_ellipsize(subject_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_box_pack_start(content, subject_widget, 0, 0, 0);

    const snippet_widget = c.gtk_label_new(null);
    const snippet_label: *c.GtkLabel = @ptrCast(snippet_widget);
    setLabelDim(app.gpa, snippet_label, msg.data.snippet);
    c.gtk_label_set_xalign(snippet_label, 0);
    c.gtk_label_set_ellipsize(snippet_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_box_pack_start(content, snippet_widget, 0, 0, 0);

    const event_container: *c.GtkContainer = @ptrCast(event_box_widget);
    c.gtk_container_add(event_container, content_widget);

    const open_ctx = try app.gpa.create(OpenContext);
    errdefer app.gpa.destroy(open_ctx);
    open_ctx.* = .{ .app = app, .thread_id = try app.gpa.dupe(u8, msg.data.thread_id) };
    _ = c.g_signal_connect_data(event_box_widget, "button-press-event", @ptrCast(&onRowClicked), open_ctx, OpenContext.destroy, 0);

    c.gtk_box_pack_start(root, event_box_widget, 1, 1, 0);

    // Action buttons, right-aligned. Delete last/rightmost, not first:
    // the most destructive action deserves to be the one you have to
    // reach furthest for, not the one closest to an accidental click.
    const button_row_widget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    const button_row: *c.GtkBox = @ptrCast(button_row_widget);
    try addActionButton(app, button_row, msg.data.id, .archive);
    try addActionButton(app, button_row, msg.data.id, .mark_read);
    try addActionButton(app, button_row, msg.data.id, .trash);
    c.gtk_box_pack_start(root, button_row_widget, 0, 0, 0);

    return root_widget;
}

fn updateHeader(app: *AppState, text: []const u8) void {
    const escaped = status.escapePango(app.gpa, text) catch return;
    defer app.gpa.free(escaped);
    const markup = std.fmt.allocPrintSentinel(app.gpa, "<b>{s}</b>", .{escaped}, 0) catch return;
    defer app.gpa.free(markup);
    c.gtk_label_set_markup(@ptrCast(app.header_label), markup);
}

fn updateHeaderForCount(app: *AppState, count: usize) void {
    switch (count) {
        0 => updateHeader(app, "Gmail — No unread messages"),
        1 => updateHeader(app, "Gmail — 1 unread"),
        else => {
            const text = std.fmt.allocPrint(app.gpa, "Gmail — {d} unread", .{count}) catch return;
            defer app.gpa.free(text);
            updateHeader(app, text);
        },
    }
}

/// How many unread messages the inbox has, as far as we know: the recorded
/// total, but never less than what's actually listed (a stale total can lag
/// behind the list). The list holds at most `cfg.max_messages`, so counting
/// it alone would say "15 unread" for a 28-message inbox.
fn unreadTotal(app: *const AppState) u32 {
    const listed: u32 = @intCast(app.messages.items.len);
    return @max(app.unread_total orelse listed, listed);
}

fn updateHeaderCount(app: *AppState) void {
    updateHeaderForCount(app, unreadTotal(app));
}

/// Destroys every row widget currently in the list box (each one's
/// OpenContext/ActionContext GClosureNotify callbacks fire synchronously
/// as part of this, freeing them immediately -- there is deliberately no
/// gap here where AppState could be freed out from under them).
fn clearListBox(app: *AppState) void {
    const list_container: *c.GtkContainer = @ptrCast(app.list_box);
    if (c.gtk_container_get_children(list_container)) |children| {
        var node: ?*c.GList = children;
        while (node) |n| {
            const child: *c.GtkWidget = @ptrCast(@alignCast(n.data.?));
            c.gtk_widget_destroy(child);
            node = n.next;
        }
        c.g_list_free(children);
    }
}

/// Destroys one message's row. `row` is the widget buildRow returned, but
/// gtk_container_add on a GtkListBox wraps it in a GtkListBoxRow of its
/// own -- destroying only the inner widget (as this used to) leaves that
/// empty wrapper behind in the list, one more per action. Destroy the
/// wrapper, which takes the inner widget with it.
fn destroyRow(row: *c.GtkWidget) void {
    c.gtk_widget_destroy(c.gtk_widget_get_parent(row) orelse row);
}

/// Gives a row to buffered messages, in order, until `max_visible_rows`
/// are showing. Safe to call any time: it only ever appends, which is
/// correct because rows are handed out front-to-back and only ever removed,
/// so a message that newly qualifies always belongs after those already
/// shown.
fn fillVisibleRows(app: *AppState) void {
    const list_container: *c.GtkContainer = @ptrCast(app.list_box);

    var shown: usize = 0;
    for (app.messages.items) |m| {
        if (m.row != null) shown += 1;
    }

    for (app.messages.items) |*msg| {
        if (shown >= max_visible_rows) break;
        if (msg.pending or msg.row != null) continue;
        const row = buildRow(app, msg) catch continue;
        msg.row = row;
        c.gtk_container_add(list_container, row);
        c.gtk_widget_show_all(row);
        shown += 1;
    }
}

/// Clears and rebuilds the list box from `app.messages`.
fn populateListFromMessages(app: *AppState) void {
    clearListBox(app);
    // clearListBox just destroyed every row widget; the `row` pointers
    // still held by messages that were showing one now dangle.
    for (app.messages.items) |*msg| msg.row = null;
    fillVisibleRows(app);
    c.gtk_widget_show_all(app.list_box);
    updateHeaderCount(app);

    // gtk-layer-shell negotiates the surface size with the compositor
    // once, at the initial configure/ack_configure handshake -- it does
    // not automatically renegotiate just because a widget's natural size
    // grew afterward. Confirmed live: the actual allocated/committed
    // surface size kept snapping back to the (tiny, ~1-message) minimum
    // shortly after adding more rows, no matter how long we waited. An
    // explicit gtk_window_resize call is required to make the compositor
    // actually grant the new size -- but calling it synchronously, right
    // here, hits gtk_widget_get_preferred_height before GTK has processed
    // the resize this function just queued (confirmed live: it returns 0,
    // tripping gtk_window_resize's own "height > 0" assertion). Deferred
    // one main-loop iteration via g_timeout_add(1, ...), by which point
    // the queued resize has been processed and the preferred height is
    // real.
    scheduleResize(app);
}

/// Queues resizeToFitContentCb for the next main-loop iteration, unless one
/// is already queued (it measures the content when it runs, so a second
/// request before then has nothing to add). The source id is kept so
/// closePopup can cancel it.
fn scheduleResize(app: *AppState) void {
    if (app.resize_timer != null) return;
    app.resize_timer = c.g_timeout_add(1, resizeToFitContentCb, app);
}

fn layerEdge(edge: placement.Edge) c.GtkLayerShellEdge {
    return switch (edge) {
        .left => c.GTK_LAYER_SHELL_EDGE_LEFT,
        .right => c.GTK_LAYER_SHELL_EDGE_RIGHT,
        .top => c.GTK_LAYER_SHELL_EDGE_TOP,
        .bottom => c.GTK_LAYER_SHELL_EDGE_BOTTOM,
    };
}

/// Anchors the popup beside the bar, lined up with where the pointer was
/// at click time, given the height it's about to have. With no pointer
/// position (the probe never got one) it sets no anchors at all, which
/// layer-shell treats as "centred on the output".
///
/// Margins and anchors are re-applied on every height change because the
/// clamp that keeps the popup on screen depends on the height.
fn applyPlacement(app: *AppState, popup_height: c.gint) void {
    const pointer = app.pointer orelse return;
    const layout = placement.compute(pointer, popup_width, popup_height);

    const all = [_]placement.Edge{ .left, .right, .top, .bottom };
    for (all) |edge| {
        const anchored = edge == layout.bar_edge or edge == layout.cross_edge;
        c.gtk_layer_set_anchor(app.window, layerEdge(edge), @intFromBool(anchored));
    }
    c.gtk_layer_set_margin(app.window, layerEdge(layout.bar_edge), layout.bar_margin);
    c.gtk_layer_set_margin(app.window, layerEdge(layout.cross_edge), layout.cross_margin);
}

fn resizeToFitContentCb(user_data: c.gpointer) callconv(.c) c.gboolean {
    const app: *AppState = @ptrCast(@alignCast(user_data.?));
    app.resize_timer = null; // this source is removed on return regardless

    // gtk_widget_set_size_request below makes the size request a *minimum*
    // the window's preferred height can never go under, so measuring with
    // the previous request still in place could only ever report "same or
    // taller" -- the window would never shrink. Measure the content's own
    // height, then put the request back if nothing changed.
    c.gtk_widget_set_size_request(@ptrCast(app.window), popup_width, -1);
    var natural_height: c.gint = 0;
    c.gtk_widget_get_preferred_height(@ptrCast(app.window), null, &natural_height);

    if (natural_height <= 0 or natural_height == app.last_height) {
        const previous: c.gint = if (app.last_height > 0) app.last_height else -1;
        c.gtk_widget_set_size_request(@ptrCast(app.window), popup_width, previous);
        return 0;
    }

    {
        app.last_height = natural_height;
        // The compositor answers a size change under a stationary pointer
        // with a leave-notify (the pointer may no longer be over us);
        // flag that so onWindowLeave doesn't mistake it for the user
        // moving away.
        app.ignore_leave_until_us = c.g_get_monotonic_time() + resize_leave_grace_us;
        applyPlacement(app, natural_height);
        // gtk-layer-shell's own header comment documents this exact
        // two-call pattern: set_size_request first (the real target
        // size), then gtk_window_resize with throwaway arguments purely
        // to make gtk-layer-shell re-read that size request and push a
        // fresh zwlr_layer_surface_v1.set_size to the compositor -- it
        // does not do this on its own just because the window's natural
        // size changed. Confirmed via WAYLAND_DEBUG=1: without the
        // gtk_window_resize call, no new set_size is ever sent at all,
        // no matter how the request is made or how long you wait.
        c.gtk_widget_set_size_request(@ptrCast(app.window), popup_width, natural_height);
        c.gtk_window_resize(app.window, 1, 1);
    }
    return 0; // G_SOURCE_REMOVE: one-shot
}

fn findMessageIndex(app: *AppState, message_id: []const u8) ?usize {
    for (app.messages.items, 0..) |m, i| {
        if (std.mem.eql(u8, m.data.id, message_id)) return i;
    }
    return null;
}

/// The row for `message_id` has already been destroyed optimistically by
/// onActionClicked by the time this runs (see PendingActionContext).
fn performAction(app: *AppState, message_id: []const u8, kind: ActionKind) void {
    const idx = findMessageIndex(app, message_id) orelse return;

    var client = http.Client.initFromEnv(app.gpa, app.io, app.environ_map);
    defer client.deinit();

    // The token is checked before every action, not just once at startup: a
    // popup left open past the access token's life (about an hour) used to
    // fail every action with 401 until it was reopened. When the cached
    // token is still good this is one small file read.
    const result: anyerror!void = blk: {
        ensureFreshToken(app) catch |err| break :blk err;
        break :blk switch (kind) {
            .mark_read => gmail.markRead(app.gpa, &client, app.access_token, message_id),
            .archive => gmail.archive(app.gpa, &client, app.access_token, message_id),
            .trash => gmail.trash(app.gpa, &client, app.access_token, message_id),
        };
    };

    result catch |err| {
        std.debug.print("waybar-gmail-popup: {s} on {s} failed: {t}\n", .{ @tagName(kind), message_id, err });
        const msg = std.fmt.allocPrint(app.gpa, "Gmail — {s} failed, try again", .{@tagName(kind)}) catch "Gmail — action failed";
        defer if (!std.mem.eql(u8, msg, "Gmail — action failed")) app.gpa.free(msg);
        updateHeader(app, msg);
        app.messages.items[idx].pending = false;
        populateListFromMessages(app); // the message is still in app.messages -- just re-render it
        return;
    };

    var removed = app.messages.orderedRemove(idx);
    if (removed.row) |row| destroyRow(row);
    removed.deinit(app.gpa);
    // One fewer unread (archive and trash both leave the inbox; mark-read
    // clears UNREAD). Saturating, since the recorded total can be stale.
    if (app.unread_total) |t| app.unread_total = t -| 1;
    fillVisibleRows(app); // normally a no-op: onActionClicked already refilled
    persistCaches(app);
    notifyWaybar(app.io);

    // The last message is gone: nothing left to act on, so close. This
    // only happens once the list is really empty -- an earlier version
    // closed the window after a *single* action, which was reported live
    // as "should stay open to allow several actions to be done at once",
    // and that is still the behavior whenever anything remains (the 5-row
    // cap only limits what's shown; buffered messages count as remaining).
    //
    // closePopup frees `app`, so nothing below may touch it, and neither
    // may the caller: see performActionDeferredCb. A popup that is merely
    // *opened* on an empty inbox does not go through here and stays open
    // showing "No unread messages".
    if (app.messages.items.len == 0) {
        closePopup(app);
        return;
    }

    updateHeaderCount(app);

    // The row is already gone (destroyed optimistically by
    // onActionClicked, before this even ran) -- but unlike
    // populateListFromMessages's full rebuild elsewhere, that direct
    // removal never re-triggers the gtk-layer-shell resize dance (see
    // resizeToFitContentCb's own comment for why one is needed at all).
    // Without this, the window stayed at its pre-action size, one
    // row's worth too tall, after every single action. (While more than
    // `max_visible_rows` messages remain, the refill keeps the height
    // identical and resizeToFitContentCb returns without touching anything.)
    scheduleResize(app);
}

/// Makes sure `app.access_token` is valid, refreshing it if the cached one is
/// near expiry. When it isn't, this is one small file read. Called before
/// anything that talks to the API -- the refresh on open, and every action.
fn ensureFreshToken(app: *AppState) !void {
    var http_client: std.http.Client = .{ .allocator = app.gpa, .io = app.io };
    defer http_client.deinit();
    const new_token = try oauth.getValidAccessToken(app.gpa, app.io, &http_client, app.creds, app.state_dir);
    oauth.secureFree(app.gpa, app.access_token);
    app.access_token = new_token;
}

/// The inbox's real unread total (one cheap call), or null if it couldn't be
/// read -- the list is capped at `max_messages`, so it can't tell us.
fn fetchUnreadTotal(app: *AppState) ?u32 {
    var client = http.Client.initFromEnv(app.gpa, app.io, app.environ_map);
    defer client.deinit();
    return gmail.getUnreadCount(app.gpa, &client, app.access_token) catch |err| {
        std.debug.print("waybar-gmail-popup: couldn't read the unread count: {t}\n", .{err});
        return null;
    };
}

/// A refresh failed. If nothing is on screen from the cache either, say so:
/// otherwise the header sits on "loading…" forever. With cached content
/// showing it's left alone -- slightly stale beats blank.
fn showLoadFailure(app: *AppState, err: anyerror) void {
    if (app.messages.items.len != 0) return;
    updateHeader(app, switch (err) {
        error.NotAuthenticated, error.Unauthorized => "Gmail — not signed in (run: waybar-gmail auth)",
        error.RateLimited => "Gmail — rate limited, try again shortly",
        else => "Gmail — couldn't load (check your connection)",
    });
}

fn refreshTimeoutCb(user_data: c.gpointer) callconv(.c) c.gboolean {
    const app: *AppState = @ptrCast(@alignCast(user_data.?));

    ensureFreshToken(app) catch |err| {
        std.debug.print("waybar-gmail-popup: token refresh failed: {t}\n", .{err});
        showLoadFailure(app, err);
        return 0; // G_SOURCE_REMOVE -- keep whatever cached content was already shown
    };

    const total = fetchUnreadTotal(app);

    const fetched = fetchMessages(app) catch |err| {
        std.debug.print("waybar-gmail-popup: refresh failed: {t}\n", .{err});
        showLoadFailure(app, err);
        return 0; // G_SOURCE_REMOVE -- keep whatever was already shown (cache or empty)
    };

    for (app.messages.items) |*m| m.deinit(app.gpa);
    app.messages.deinit(app.gpa);
    app.messages = .fromOwnedSlice(fetched);
    if (total) |t| app.unread_total = t;

    populateListFromMessages(app);
    persistCaches(app);
    return 0; // G_SOURCE_REMOVE: one-shot
}

/// Tears down the popup in an order this code controls completely,
/// rather than one relying on GTK's own signal-emission ordering.
///
/// The original version of this function just called
/// `gtk_widget_destroy(window)` and freed AppState from a "destroy"
/// signal handler on that window, on the assumption that destroying a
/// widget synchronously cascades through and finalizes every child first.
/// Live-tested and confirmed false: GtkWidget's own "destroy" signal
/// completes (all handlers, G_CONNECT_AFTER or not) *before* the
/// container's children are actually torn down -- child destruction
/// happens later, via GObject's separate dispose/finalize sequence, not
/// as part of that signal emission. That ordering freed AppState while
/// every row's OpenContext/ActionContext (each holding a *AppState
/// captured at row-build time) was still live, so their GClosureNotify
/// callbacks later dereferenced already-freed memory -- confirmed
/// directly by instrumenting both sides: `destroyAppState` printed and
/// returned before a single row's cleanup callback ever ran.
///
/// Fixed by not depending on that ordering at all: explicitly destroy
/// every row first (their cleanup runs immediately, while AppState still
/// exists), only then destroy the window, and free AppState directly
/// ourselves rather than through a signal.
fn closePopup(app: *AppState) void {
    if (app.closing) return;
    app.closing = true;
    // A pending hover-close timer left scheduled here would fire 500ms
    // from now against an AppState this function is about to free --
    // cancel it regardless of which path is actually closing the popup.
    if (app.hover_close_timer) |id| {
        _ = c.g_source_remove(id);
        app.hover_close_timer = null;
    }
    // Same for a queued resize: e.g. two quick actions on the last two
    // messages, the first of which queued a resize, the second of which
    // emptied the list and closed the popup.
    if (app.resize_timer) |id| {
        _ = c.g_source_remove(id);
        app.resize_timer = null;
    }
    clearListBox(app);
    c.gtk_widget_destroy(@ptrCast(app.window));
    app.deinit();
}

fn onKeyPress(_: *c.GtkWidget, event: *c.GdkEvent, user_data: c.gpointer) callconv(.c) c.gboolean {
    const app: *AppState = @ptrCast(@alignCast(user_data.?));
    var keyval: c.guint = 0;
    if (c.gdk_event_get_keyval(event, &keyval) != 0 and keyval == c.GDK_KEY_Escape) {
        closePopup(app);
    }
    return 0;
}

/// Not the same failure mode as the focus-in/focus-out attempts
/// documented in onActivate's own comment: those were about *keyboard*
/// focus, which a newly-created ON_DEMAND layer-shell surface can be
/// granted and lose spuriously as part of its own setup, independent of
/// anything the user does. Enter/leave-notify are *pointer* crossing
/// events tied to actual mouse movement over the surface, not keyboard
/// focus negotiation -- a different event class without that
/// documented failure mode.
fn onWindowEnter(_: *c.GtkWidget, _: *c.GdkEvent, user_data: c.gpointer) callconv(.c) c.gboolean {
    const app: *AppState = @ptrCast(@alignCast(user_data.?));
    if (app.hover_close_timer) |id| {
        _ = c.g_source_remove(id);
        app.hover_close_timer = null;
    }
    return 0;
}

fn onWindowLeave(_: *c.GtkWidget, event: *c.GdkEvent, user_data: c.gpointer) callconv(.c) c.gboolean {
    const app: *AppState = @ptrCast(@alignCast(user_data.?));

    // Two kinds of leave-notify aren't the pointer leaving the popup.
    //
    // 1. The pointer moving from the window onto one of its own child
    //    windows -- the scrolled viewport, a row's event box, a button's
    //    input window. GDK reports that as a leave on the window with
    //    detail INFERIOR, and GTK never sends the matching enter to the
    //    toplevel (crossing events aren't propagated up), so onWindowEnter
    //    can't cancel the timer this would start. That is what closed the
    //    popup shortly after hovering a button.
    const crossing: *const c.GdkEventCrossing = @ptrCast(@alignCast(event));
    if (crossing.detail == c.GDK_NOTIFY_INFERIOR) return 0;

    // 2. The compositor's reaction to the popup resizing under a pointer
    //    that hasn't moved (an action removed a row and the popup shrank
    //    out from under it). Don't close on the spot -- the user is most
    //    likely about to click the next row's button -- but don't leave
    //    the popup stranded open either if they really did move away: close
    //    after a longer grace period. Re-entering cancels it (onWindowEnter).
    const resize_echo = c.g_get_monotonic_time() < app.ignore_leave_until_us;
    const delay_ms: c.guint = if (resize_echo) post_resize_close_delay_ms else 500;

    // Moving between two child widgets (e.g. adjacent action buttons)
    // can transiently cross the window's own boundary and back; only
    // start a new timer if one isn't already pending, so rapid
    // leave/enter pairs don't keep resetting a close that was already
    // in flight for no reason (harmless either way, but avoidable).
    if (app.hover_close_timer == null) {
        app.hover_close_timer = c.g_timeout_add(delay_ms, hoverCloseTimeoutCb, app);
    }
    return 0;
}

fn hoverCloseTimeoutCb(user_data: c.gpointer) callconv(.c) c.gboolean {
    const app: *AppState = @ptrCast(@alignCast(user_data.?));
    app.hover_close_timer = null; // this source is about to be removed regardless (G_SOURCE_REMOVE)
    closePopup(app);
    return 0; // G_SOURCE_REMOVE: one-shot
}

// ---- activation ----

fn setupAppState(init_data: std.process.Init, gtk_app: *c.GtkApplication) !*AppState {
    const gpa = init_data.gpa;
    const io = init_data.io;

    var dirs = try config.openDirs(gpa, io, init_data.environ_map);
    // On any subsequent failure, close both dirs and free both path
    // strings via Dirs.deinit. On success, only the path strings are
    // freed (explicitly, below, exactly once) -- their job of opening
    // config_dir/state_dir is done, but those Dir handles themselves are
    // kept open, owned from here on by AppState, not closed.
    errdefer dirs.deinit(gpa, io);

    var creds = try oauth.loadClientCredentials(gpa, io, dirs.config_dir, "client_secret.json");
    errdefer creds.deinit(gpa);

    // Deliberately not fetched here: reading/refreshing the access token
    // can be a full network round trip to Google's token endpoint (any
    // time the cached one is within `expiry_safety_margin_s` of expiring),
    // and this function runs before any widget exists. Doing that here
    // blocked window creation on network I/O -- confirmed live, the
    // window did not appear for several seconds while this refreshed.
    // The real token is fetched by `ensureFreshToken`: in `refreshTimeoutCb`
    // (which runs via `g_timeout_add` *after* `gtk_widget_show_all`, so the
    // window is on screen with cached content before any network call) and
    // again before every action, so a popup left open past the token's
    // lifetime keeps working.
    const access_token = try gpa.alloc(u8, 0);
    errdefer gpa.free(access_token);

    // Infallible: a missing or broken config.json just means defaults.
    const cfg = config.load(gpa, io, dirs.config_dir);
    // The inbox total the status poll last recorded, so the header can show
    // it immediately; null (header falls back to the listed count) if the
    // poll hasn't run yet.
    const unread_total = status.loadUnreadCount(gpa, io, dirs.state_dir);

    const app = try gpa.create(AppState);

    // No fallible operation remains after this point in the function, so
    // freeing the path strings here can never race with the errdefers
    // above (which would otherwise double-free them on a failure this
    // late -- e.g. gpa.create itself failing under OOM).
    gpa.free(dirs.config_path);
    gpa.free(dirs.state_path);

    app.* = .{
        .gpa = gpa,
        .io = io,
        .environ_map = init_data.environ_map,
        .creds = creds,
        .config_dir = dirs.config_dir,
        .state_dir = dirs.state_dir,
        .access_token = access_token,
        .cfg = cfg,
        .unread_total = unread_total,
        .gtk_app = gtk_app,
        .window = undefined,
        .list_box = undefined,
        .header_label = undefined,
    };
    return app;
}

// ---- placement probe ----
//
// The popup should open next to the icon that was clicked, wherever the bar
// is. Waybar passes `on-click` no coordinates and Wayland clients can't ask
// where another client drew something, but at click time the pointer is on
// that icon. So before building the real popup, map a fully transparent,
// output-sized overlay surface: the compositor sends it a pointer enter
// with the pointer's position, and the nearest screen edge tells us which
// side the bar is on (see placement.zig). The probe is gone again within a
// few milliseconds.
//
// A compositor only sends a surface a pointer `enter` when the pointer
// moves, and at click time it is stationary -- confirmed live on sway, whose
// protocol trace shows the probe mapped at full size and no wl_pointer event
// at all. So on sway the probe asks for a zero-distance pointer move, which
// makes it re-evaluate pointer focus (see nudgePointer).
//
// Falls back to a centred popup if no pointer event arrives in time.

const probe_timeout_ms: c.guint = 250;

/// The nudge repeats because the first one can land before the probe is
/// actually mapped (a surface that hasn't committed a buffer yet can't take
/// pointer focus); it stops as soon as the probe has seen the pointer. The
/// attempts all fit inside `probe_timeout_ms`.
const probe_nudge_interval_ms: c.guint = 40;
const probe_max_nudges = 4;

/// Asks sway to move the pointer by nothing. Nothing visibly moves, but
/// sway treats it as pointer motion and delivers `enter` (with exact
/// coordinates) to whatever surface is under the pointer -- now the probe.
///
/// Best effort and sway-specific: with no `swaymsg` (another compositor) or
/// no sway socket this silently does nothing, and the probe's timeout falls
/// back to centring. Waits for the child, like notifyWaybar, so it can't
/// leave a zombie behind in this long-lived process; swaymsg returns in
/// milliseconds.
fn nudgePointer(io: Io) void {
    var child = std.process.spawn(io, .{
        .argv = &.{ "swaymsg", "seat", "-", "cursor", "move", "0", "0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(io) catch {};
}

fn probeNudgeCb(user_data: c.gpointer) callconv(.c) c.gboolean {
    const app: *AppState = @ptrCast(@alignCast(user_data.?));
    if (app.probe == null or app.probe_xy != null) {
        app.probe_nudge_timer = null;
        return 0; // G_SOURCE_REMOVE
    }
    nudgePointer(app.io);
    app.probe_nudges += 1;
    if (app.probe_nudges >= probe_max_nudges) {
        app.probe_nudge_timer = null;
        return 0; // G_SOURCE_REMOVE
    }
    return 1; // G_SOURCE_CONTINUE
}

/// Paints the probe fully transparent. Returning true stops the default
/// handler, which would otherwise paint the theme's window background over it.
fn onProbeDraw(_: *c.GtkWidget, cr: *c.cairo_t, _: c.gpointer) callconv(.c) c.gboolean {
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
    c.cairo_paint(cr);
    return 1;
}

fn onProbePointer(_: *c.GtkWidget, event: *c.GdkEvent, user_data: c.gpointer) callconv(.c) c.gboolean {
    const app: *AppState = @ptrCast(@alignCast(user_data.?));
    if (app.probe == null or app.probe_xy != null) return 0;

    var x: f64 = 0;
    var y: f64 = 0;
    if (c.gdk_event_get_coords(event, &x, &y) == 0) return 0;
    app.probe_xy = .{ x, y };

    // finishProbe destroys the window this very handler is running on, so
    // hand off to the main loop rather than doing it mid-emission.
    _ = c.g_timeout_add(1, finishProbeCb, app);
    return 0;
}

fn finishProbeCb(user_data: c.gpointer) callconv(.c) c.gboolean {
    const app: *AppState = @ptrCast(@alignCast(user_data.?));
    finishProbe(app);
    return 0; // G_SOURCE_REMOVE: one-shot
}

fn probeTimeoutCb(user_data: c.gpointer) callconv(.c) c.gboolean {
    const app: *AppState = @ptrCast(@alignCast(user_data.?));
    app.probe_timer = null; // this source is removed on return regardless
    finishProbe(app);
    return 0; // G_SOURCE_REMOVE: one-shot
}

/// Turns whatever the probe saw into `app.pointer`, builds the real popup,
/// and only then destroys the probe -- the GtkApplication must never be
/// left with zero windows, or it quits. Idempotent: the pointer handler and
/// the fallback timer can both reach it.
fn finishProbe(app: *AppState) void {
    const probe = app.probe orelse return;
    app.probe = null;
    if (app.probe_timer) |id| {
        _ = c.g_source_remove(id);
        app.probe_timer = null;
    }
    // Must not outlive this function: a later closePopup frees `app`.
    if (app.probe_nudge_timer) |id| {
        _ = c.g_source_remove(id);
        app.probe_nudge_timer = null;
    }

    if (app.probe_xy) |xy| {
        const w = c.gtk_widget_get_allocated_width(probe);
        const h = c.gtk_widget_get_allocated_height(probe);
        // The pointer has to lie inside the surface it was reported on. If
        // it doesn't, the allocation hadn't caught up with the compositor's
        // configure yet and the output size is wrong -- better to centre
        // than to place against a made-up size.
        if (xy[0] >= 0 and xy[1] >= 0 and xy[0] < @as(f64, @floatFromInt(w)) and xy[1] < @as(f64, @floatFromInt(h))) {
            app.pointer = .{ .x = xy[0], .y = xy[1], .out_w = w, .out_h = h };
            std.debug.print("waybar-gmail-popup: placing at pointer ({d:.0}, {d:.0}) on {d}x{d} output\n", .{ xy[0], xy[1], w, h });
        } else {
            std.debug.print("waybar-gmail-popup: pointer ({d:.0}, {d:.0}) outside probe {d}x{d}, centring\n", .{ xy[0], xy[1], w, h });
        }
    } else {
        std.debug.print("waybar-gmail-popup: probe saw no pointer within {d}ms, centring\n", .{probe_timeout_ms});
    }

    showPopup(app);
    c.gtk_widget_destroy(probe);
}

fn beginProbe(app: *AppState) void {
    const widget = c.gtk_application_window_new(app.gtk_app);
    const window: *c.GtkWindow = @ptrCast(widget);
    c.gtk_window_set_title(window, "Gmail (placement probe)");

    // Transparent: an RGBA visual (if the screen has one) plus our own draw
    // handler that never paints anything.
    if (c.gdk_screen_get_rgba_visual(c.gtk_widget_get_screen(widget))) |visual| {
        c.gtk_widget_set_visual(widget, visual);
    }
    c.gtk_widget_set_app_paintable(widget, 1);

    c.gtk_layer_init_for_window(window);
    c.gtk_layer_set_layer(window, c.GTK_LAYER_SHELL_LAYER_OVERLAY);
    c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_LEFT, 1);
    c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_RIGHT, 1);
    c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_TOP, 1);
    c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_BOTTOM, 1);
    // -1: cover the whole output, including the bar's own exclusive zone.
    // Otherwise the surface would start beside the bar and the coordinates
    // it reports would be offset from the output's origin.
    c.gtk_layer_set_exclusive_zone(window, -1);
    c.gtk_layer_set_keyboard_mode(window, c.GTK_LAYER_SHELL_KEYBOARD_MODE_NONE);
    c.gtk_layer_set_namespace(window, "waybar-gmail-probe");

    c.gtk_widget_add_events(widget, c.GDK_ENTER_NOTIFY_MASK | c.GDK_POINTER_MOTION_MASK);
    _ = c.g_signal_connect_data(window, "draw", @ptrCast(&onProbeDraw), null, null, 0);
    _ = c.g_signal_connect_data(window, "enter-notify-event", @ptrCast(&onProbePointer), app, null, 0);
    _ = c.g_signal_connect_data(window, "motion-notify-event", @ptrCast(&onProbePointer), app, null, 0);

    app.probe = widget;
    app.probe_timer = c.g_timeout_add(probe_timeout_ms, probeTimeoutCb, app);
    app.probe_nudge_timer = c.g_timeout_add(probe_nudge_interval_ms, probeNudgeCb, app);
    c.gtk_widget_show_all(widget);
}

fn onActivate(gtk_app: ?*c.GtkApplication, user_data: c.gpointer) callconv(.c) void {
    const init_data: *const std.process.Init = @ptrCast(@alignCast(user_data.?));

    const app = setupAppState(init_data.*, gtk_app.?) catch |err| {
        std.debug.print("waybar-gmail-popup: couldn't start: {t}\n", .{err});
        c.g_application_quit(@ptrCast(gtk_app.?));
        return;
    };

    // The real popup is built by finishProbe, once we know where to put it.
    beginProbe(app);
}

/// Builds and shows the actual popup window.
fn showPopup(app: *AppState) void {
    const window_widget = c.gtk_application_window_new(app.gtk_app);
    const window: *c.GtkWindow = @ptrCast(window_widget);
    app.window = window;
    c.gtk_window_set_title(window, "Gmail");
    // Deliberately no gtk_window_set_default_size: that sets the size
    // the window opens at regardless of content, which forced 400px of
    // height (mostly blank) even with zero or one message. Fixing the
    // width but leaving height at -1 (natural) lets the window's actual
    // size come from its children -- header + however tall the list of
    // messages actually is.
    c.gtk_widget_set_size_request(window_widget, popup_width, -1);

    c.gtk_layer_init_for_window(window);
    c.gtk_layer_set_layer(window, c.GTK_LAYER_SHELL_LAYER_TOP);
    // Anchors and margins from where the pointer was; re-applied with the
    // measured height by resizeToFitContentCb once there is one.
    applyPlacement(app, initial_height_estimate);
    c.gtk_layer_set_keyboard_mode(window, c.GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND);
    c.gtk_layer_set_namespace(window, "waybar-gmail");

    const outer_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    const outer: *c.GtkBox = @ptrCast(outer_widget);

    const header_widget = c.gtk_label_new(null);
    app.header_label = header_widget;
    c.gtk_label_set_xalign(@ptrCast(header_widget), 0);
    c.gtk_widget_set_margin_start(header_widget, 10);
    c.gtk_widget_set_margin_end(header_widget, 10);
    c.gtk_widget_set_margin_top(header_widget, 8);
    c.gtk_widget_set_margin_bottom(header_widget, 4);
    c.gtk_box_pack_start(outer, header_widget, 0, 0, 0);

    const scrolled_widget = c.gtk_scrolled_window_new(null, null);
    // Size to content, no max_content_height cap: the list can never hold
    // more than `max_visible_rows` rows (the rest of the fetched messages
    // are buffered, not rendered -- see fillVisibleRows), so it never needs
    // to scroll and its natural height is always the right height.
    // GtkScrolledWindow is kept rather than a plain box only because the
    // layout was tuned around it (see fetchMessages's doc comment).
    c.gtk_scrolled_window_set_propagate_natural_height(scrolled_widget, 1);
    const list_box_widget = c.gtk_list_box_new();
    app.list_box = list_box_widget;
    c.gtk_container_add(@ptrCast(scrolled_widget), list_box_widget);
    c.gtk_box_pack_start(outer, scrolled_widget, 1, 1, 0);

    c.gtk_container_add(@ptrCast(window), outer_widget);

    _ = c.g_signal_connect_data(window, "key-press-event", @ptrCast(&onKeyPress), app, null, 0);
    // Deliberately no focus-out-event handler: tried (twice) to close the
    // popup automatically when it loses *keyboard* focus, and both
    // attempts were real bugs, not edge cases -- a newly created
    // layer-shell surface gets what looks like a genuine focus-in
    // immediately followed by a focus-out as part of the compositor's
    // own window-setup sequence, not real user interaction, and this
    // happens with unpredictable timing (confirmed by the same
    // reproduction sometimes surviving 2+ seconds and sometimes not,
    // testing live). There's no reliable way to distinguish that from an
    // actual "user clicked away" from inside this process.
    //
    // enter/leave-notify below are a different event class -- pointer
    // crossings tied to actual mouse movement, not keyboard focus
    // negotiation -- and don't share that failure mode. Closing overall
    // is handled by: Escape, this hover-leave timeout, the idle timeout
    // below (for a popup the pointer never enters), or clicking the module
    // again (click.zig already toggles an open popup closed).
    c.gtk_widget_add_events(window_widget, c.GDK_ENTER_NOTIFY_MASK | c.GDK_LEAVE_NOTIFY_MASK);
    _ = c.g_signal_connect_data(window, "enter-notify-event", @ptrCast(&onWindowEnter), app, null, 0);
    _ = c.g_signal_connect_data(window, "leave-notify-event", @ptrCast(&onWindowLeave), app, null, 0);
    // AppState is freed by closePopup itself (clearListBox, then destroy
    // the window, then app.deinit()), not via a "destroy" signal handler
    // -- see closePopup's own comment for why that ordering matters.

    // Paint from the structured cache immediately, if one exists, so the
    // window has real content the instant it appears.
    var cache_is_fresh = false;
    if (loadMessagesCache(app.gpa, app.io, app.state_dir)) |cached| {
        app.messages = cached;
        populateListFromMessages(app);
        cache_is_fresh = messages_cache.isFresh(app.io, app.state_dir, messages_cache.fresh_max_age_ms);
    } else {
        updateHeader(app, "Gmail — loading…");
    }

    c.gtk_widget_show_all(window_widget);

    // A popup nobody touches would otherwise sit on screen indefinitely:
    // the hover-leave timer only starts once the pointer has entered and
    // left, and this popup opens beside the pointer, not under it. Started
    // here, cancelled the moment the pointer enters (onWindowEnter), and
    // restarted by every leave as before.
    if (app.cfg.idle_close_ms > 0) {
        app.hover_close_timer = c.g_timeout_add(app.cfg.idle_close_ms, hoverCloseTimeoutCb, app);
    }

    // Refresh from Gmail once the window is already on screen -- unless the
    // cache we just painted is fresh. The status poll rewrites it every
    // minute while anything is unread, so it normally is, and the popup
    // then opens instantly with no network round trip at all (the refresh
    // runs on the GTK main thread, so while it ran the window couldn't be
    // clicked, hovered or closed). It still happens when the cache is
    // missing or stale, e.g. right after login or if the poll isn't running.
    // Actions fetch their own fresh token (see performAction).
    if (!cache_is_fresh) {
        _ = c.g_timeout_add(1, refreshTimeoutCb, app);
    }
}

pub fn run(init: std.process.Init) u8 {
    const gtk_app = c.gtk_application_new("dev.waybar-gmail.popup", c.G_APPLICATION_FLAGS_NONE);
    defer c.g_object_unref(gtk_app);

    _ = c.g_signal_connect_data(gtk_app, "activate", @ptrCast(&onActivate), @constCast(&init), null, 0);

    const status_code = c.g_application_run(@ptrCast(gtk_app), 0, null);
    // g_application_run's c_int return is conventionally a small
    // non-negative exit code, but that's GLib's convention, not a
    // documented guarantee -- a raw @intCast to u8 would panic on
    // anything outside 0-255, which would be an avoidable crash on this
    // program's very last line. std.math.cast fails safely to null
    // instead, mapped to a generic non-zero exit code.
    return std.math.cast(u8, status_code) orelse 1;
}
