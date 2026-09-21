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
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;
const c = @import("c.zig");
const cache = @import("cache.zig");
const config = @import("config.zig");
const gmail = @import("gmail.zig");
const http = @import("http.zig");
const oauth = @import("oauth.zig");
const status = @import("status.zig");

const messages_cache_file = "messages.json";
const max_messages_cache_size = 256 * 1024;

const CachedMessage = struct {
    id: []u8,
    thread_id: []u8,
    from: []u8,
    subject: []u8,
    snippet: []u8,
    row: ?*c.GtkWidget = null,

    fn deinit(self: *CachedMessage, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.thread_id);
        gpa.free(self.from);
        gpa.free(self.subject);
        gpa.free(self.snippet);
        self.* = undefined;
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
    gtk_app: *c.GtkApplication,
    window: *c.GtkWindow,
    list_box: *c.GtkWidget,
    header_label: *c.GtkWidget,
    messages: std.ArrayList(CachedMessage) = .empty,
    /// Guards against closePopup running twice: GTK signals that can
    /// legitimately fire close to simultaneously (a focus-out arriving
    /// right as Escape is pressed, for instance) must not both try to
    /// destroy the same window -- the second gtk_widget_destroy would
    /// operate on an already-finalized widget, and AppState itself would
    /// be freed twice via the resulting double "destroy" signal.
    closing: bool = false,

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

const CachedMessageJson = struct {
    id: []const u8,
    thread_id: []const u8,
    from: []const u8,
    subject: []const u8,
    snippet: []const u8,
};

fn saveMessagesCache(app: *AppState) !void {
    var list: std.ArrayList(CachedMessageJson) = .empty;
    defer list.deinit(app.gpa);
    for (app.messages.items) |m| {
        try list.append(app.gpa, .{ .id = m.id, .thread_id = m.thread_id, .from = m.from, .subject = m.subject, .snippet = m.snippet });
    }

    var out: Io.Writer.Allocating = .init(app.gpa);
    defer out.deinit();
    try std.json.Stringify.value(list.items, .{}, &out.writer);
    try cache.atomicWrite(app.state_dir, app.io, messages_cache_file, out.written(), cache.private_file_permissions);
}

fn loadMessagesCache(gpa: Allocator, io: Io, dir: Dir) ?std.ArrayList(CachedMessage) {
    const raw = gpa.alloc(u8, max_messages_cache_size) catch return null;
    defer gpa.free(raw);
    const data = dir.readFile(io, messages_cache_file, raw) catch return null;

    const parsed = std.json.parseFromSlice([]CachedMessageJson, gpa, data, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();

    var out: std.ArrayList(CachedMessage) = .empty;
    for (parsed.value) |m| {
        const entry = CachedMessage{
            .id = gpa.dupe(u8, m.id) catch break,
            .thread_id = gpa.dupe(u8, m.thread_id) catch break,
            .from = gpa.dupe(u8, m.from) catch break,
            .subject = gpa.dupe(u8, m.subject) catch break,
            .snippet = gpa.dupe(u8, m.snippet) catch break,
        };
        out.append(gpa, entry) catch break;
    }
    return out;
}

fn persistCaches(app: *AppState) void {
    saveMessagesCache(app) catch |err| {
        std.debug.print("waybar-gmail-popup: couldn't save message cache: {t}\n", .{err});
    };

    var lines: std.ArrayList([]const u8) = .empty;
    defer {
        for (lines.items) |l| app.gpa.free(l);
        lines.deinit(app.gpa);
    }
    for (app.messages.items) |m| {
        const line = std.fmt.allocPrint(app.gpa, "{s} — {s}", .{ m.from, m.subject }) catch continue;
        lines.append(app.gpa, line) catch app.gpa.free(line);
    }
    status.saveTooltipCache(app.gpa, app.io, app.state_dir, lines.items) catch |err| {
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
    var child = std.process.spawn(io, .{
        .argv = &.{ "pkill", "-RTMIN+9", "waybar" },
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

    const refs = try gmail.listUnread(app.gpa, &client, app.access_token, 15);
    defer gmail.freeMessageRefs(app.gpa, refs);

    var out: std.ArrayList(CachedMessage) = .empty;
    errdefer {
        for (out.items) |*m| m.deinit(app.gpa);
        out.deinit(app.gpa);
    }

    for (refs) |ref| {
        var preview = gmail.getPreview(app.gpa, &client, app.access_token, ref.id) catch continue;
        defer preview.deinit(app.gpa);
        try out.append(app.gpa, .{
            .id = try app.gpa.dupe(u8, ref.id),
            .thread_id = try app.gpa.dupe(u8, ref.thread_id),
            .from = try app.gpa.dupe(u8, preview.from),
            .subject = try app.gpa.dupe(u8, preview.subject),
            .snippet = try app.gpa.dupe(u8, preview.snippet),
        });
    }
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
    performAction(ctx.app, ctx.message_id, ctx.kind);
    ctx.app.gpa.free(ctx.message_id);
    ctx.app.gpa.destroy(ctx);
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
        if (app.messages.items[idx].row) |row| c.gtk_widget_destroy(row);
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
    const url = std.fmt.bufPrint(&buf, "https://mail.google.com/mail/u/0/#inbox/{s}", .{ctx.thread_id}) catch return 0;
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
    setLabelBold(app.gpa, from_label, msg.from);
    c.gtk_label_set_xalign(from_label, 0);
    c.gtk_label_set_ellipsize(from_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_box_pack_start(content, from_widget, 0, 0, 0);

    const subject_widget = c.gtk_label_new(null);
    const subject_label: *c.GtkLabel = @ptrCast(subject_widget);
    {
        const escaped = status.escapePango(app.gpa, msg.subject) catch msg.subject;
        defer if (escaped.ptr != msg.subject.ptr) app.gpa.free(escaped);
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
    setLabelDim(app.gpa, snippet_label, msg.snippet);
    c.gtk_label_set_xalign(snippet_label, 0);
    c.gtk_label_set_ellipsize(snippet_label, c.PANGO_ELLIPSIZE_END);
    c.gtk_box_pack_start(content, snippet_widget, 0, 0, 0);

    const event_container: *c.GtkContainer = @ptrCast(event_box_widget);
    c.gtk_container_add(event_container, content_widget);

    const open_ctx = try app.gpa.create(OpenContext);
    errdefer app.gpa.destroy(open_ctx);
    open_ctx.* = .{ .app = app, .thread_id = try app.gpa.dupe(u8, msg.thread_id) };
    _ = c.g_signal_connect_data(event_box_widget, "button-press-event", @ptrCast(&onRowClicked), open_ctx, OpenContext.destroy, 0);

    c.gtk_box_pack_start(root, event_box_widget, 1, 1, 0);

    // Action buttons, right-aligned.
    const button_row_widget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
    const button_row: *c.GtkBox = @ptrCast(button_row_widget);
    try addActionButton(app, button_row, msg.id, .trash);
    try addActionButton(app, button_row, msg.id, .archive);
    try addActionButton(app, button_row, msg.id, .mark_read);
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
        0 => updateHeader(app, "Gmail — Inbox zero"),
        1 => updateHeader(app, "Gmail — 1 unread"),
        else => {
            const text = std.fmt.allocPrint(app.gpa, "Gmail — {d} unread", .{count}) catch return;
            defer app.gpa.free(text);
            updateHeader(app, text);
        },
    }
}

fn updateHeaderCount(app: *AppState) void {
    updateHeaderForCount(app, app.messages.items.len);
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

/// Clears and rebuilds the list box from `app.messages`.
fn populateListFromMessages(app: *AppState) void {
    clearListBox(app);
    const list_container: *c.GtkContainer = @ptrCast(app.list_box);

    for (app.messages.items) |*msg| {
        const row = buildRow(app, msg) catch continue;
        msg.row = row;
        c.gtk_container_add(list_container, row);
    }
    c.gtk_widget_show_all(app.list_box);
    updateHeaderCount(app);
}

fn findMessageIndex(app: *AppState, message_id: []const u8) ?usize {
    for (app.messages.items, 0..) |m, i| {
        if (std.mem.eql(u8, m.id, message_id)) return i;
    }
    return null;
}

/// The row for `message_id` has already been destroyed optimistically by
/// onActionClicked by the time this runs (see PendingActionContext).
fn performAction(app: *AppState, message_id: []const u8, kind: ActionKind) void {
    const idx = findMessageIndex(app, message_id) orelse return;

    var client = http.Client.initFromEnv(app.gpa, app.io, app.environ_map);
    defer client.deinit();

    const result = switch (kind) {
        .mark_read => gmail.markRead(app.gpa, &client, app.access_token, message_id),
        .archive => gmail.archive(app.gpa, &client, app.access_token, message_id),
        .trash => gmail.trash(app.gpa, &client, app.access_token, message_id),
    };

    result catch |err| {
        std.debug.print("waybar-gmail-popup: {s} on {s} failed: {t}\n", .{ @tagName(kind), message_id, err });
        const msg = std.fmt.allocPrint(app.gpa, "Gmail — {s} failed, try again", .{@tagName(kind)}) catch "Gmail — action failed";
        defer if (!std.mem.eql(u8, msg, "Gmail — action failed")) app.gpa.free(msg);
        updateHeader(app, msg);
        populateListFromMessages(app); // the message is still in app.messages -- just re-render it
        return;
    };

    var removed = app.messages.orderedRemove(idx);
    removed.deinit(app.gpa);
    persistCaches(app);
    notifyWaybar(app.io);

    // Deliberately does not close the popup when the list empties: it
    // used to, and that closed the window out from under the user after
    // a single action -- reported live as "should stay open to allow
    // several actions to be done at once". The window now stays open
    // showing "Inbox zero" until the user dismisses it themselves
    // (Escape, or clicking the module again).
    updateHeaderCount(app);
}

fn refreshTimeoutCb(user_data: c.gpointer) callconv(.c) c.gboolean {
    const app: *AppState = @ptrCast(@alignCast(user_data.?));

    var http_client: std.http.Client = .{ .allocator = app.gpa, .io = app.io };
    const new_token = oauth.getValidAccessToken(app.gpa, app.io, &http_client, app.creds, app.state_dir) catch |err| {
        http_client.deinit();
        std.debug.print("waybar-gmail-popup: token refresh failed: {t}\n", .{err});
        return 0; // G_SOURCE_REMOVE -- keep whatever cached content was already shown
    };
    http_client.deinit();
    oauth.secureFree(app.gpa, app.access_token);
    app.access_token = new_token;

    const fetched = fetchMessages(app) catch |err| {
        std.debug.print("waybar-gmail-popup: refresh failed: {t}\n", .{err});
        return 0; // G_SOURCE_REMOVE -- keep whatever was already shown (cache or empty)
    };

    for (app.messages.items) |*m| m.deinit(app.gpa);
    app.messages.deinit(app.gpa);
    app.messages = .fromOwnedSlice(fetched);

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
    // The real token is fetched in `refreshTimeoutCb`, which runs via
    // `g_timeout_add` *after* `gtk_widget_show_all`, so the window is on
    // screen (with cached content, if any) before any network call.
    const access_token = try gpa.alloc(u8, 0);
    errdefer gpa.free(access_token);

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
        .gtk_app = gtk_app,
        .window = undefined,
        .list_box = undefined,
        .header_label = undefined,
    };
    return app;
}

fn onActivate(gtk_app: ?*c.GtkApplication, user_data: c.gpointer) callconv(.c) void {
    const init_data: *const std.process.Init = @ptrCast(@alignCast(user_data.?));

    const app = setupAppState(init_data.*, gtk_app.?) catch |err| {
        std.debug.print("waybar-gmail-popup: couldn't start: {t}\n", .{err});
        c.g_application_quit(@ptrCast(gtk_app.?));
        return;
    };

    const window_widget = c.gtk_application_window_new(gtk_app.?);
    const window: *c.GtkWindow = @ptrCast(window_widget);
    app.window = window;
    c.gtk_window_set_title(window, "Gmail");
    // Deliberately no gtk_window_set_default_size: that sets the size
    // the window opens at regardless of content, which forced 400px of
    // height (mostly blank) even with zero or one message. Fixing the
    // width but leaving height at -1 (natural) lets the window's actual
    // size come from its children -- header + however tall the list
    // ends up being, capped by gtk_scrolled_window_set_max_content_height
    // below.
    c.gtk_widget_set_size_request(window_widget, 360, -1);

    c.gtk_layer_init_for_window(window);
    c.gtk_layer_set_layer(window, c.GTK_LAYER_SHELL_LAYER_TOP);
    c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_TOP, 1);
    c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_RIGHT, 1);
    c.gtk_layer_set_margin(window, c.GTK_LAYER_SHELL_EDGE_TOP, 34);
    c.gtk_layer_set_margin(window, c.GTK_LAYER_SHELL_EDGE_RIGHT, 8);
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
    // Size to content up to 340px, rather than always claiming 340px --
    // the fixed size_request this replaced left a block of empty space
    // below the list whenever there were fewer than ~3 messages.
    c.gtk_scrolled_window_set_propagate_natural_height(scrolled_widget, 1);
    c.gtk_scrolled_window_set_max_content_height(scrolled_widget, 340);
    const list_box_widget = c.gtk_list_box_new();
    app.list_box = list_box_widget;
    c.gtk_container_add(@ptrCast(scrolled_widget), list_box_widget);
    c.gtk_box_pack_start(outer, scrolled_widget, 1, 1, 0);

    c.gtk_container_add(@ptrCast(window), outer_widget);

    _ = c.g_signal_connect_data(window, "key-press-event", @ptrCast(&onKeyPress), app, null, 0);
    // Deliberately no focus-out-event handler: tried (twice) to close the
    // popup automatically when it loses focus, and both attempts were
    // real bugs, not edge cases -- a newly created layer-shell surface
    // gets what looks like a genuine focus-in immediately followed by a
    // focus-out as part of the compositor's own window-setup sequence,
    // not real user interaction, and this happens with unpredictable
    // timing (confirmed by the same reproduction sometimes surviving
    // 2+ seconds and sometimes not, testing live). There's no reliable
    // way to distinguish that from an actual "user clicked away" from
    // inside this process. Closing is instead handled entirely by
    // explicit, unambiguous actions: Escape, an action emptying the
    // list, or clicking the module again (click.zig already toggles an
    // open popup closed).
    // AppState is freed by closePopup itself (clearListBox, then destroy
    // the window, then app.deinit()), not via a "destroy" signal handler
    // -- see closePopup's own comment for why that ordering matters.

    // Paint from the structured cache immediately, if one exists, so the
    // window has real content the instant it appears.
    if (loadMessagesCache(app.gpa, app.io, app.state_dir)) |cached| {
        app.messages = cached;
        populateListFromMessages(app);
    } else {
        updateHeader(app, "Gmail — loading…");
    }

    c.gtk_widget_show_all(window_widget);

    // Refresh from Gmail once the window is already on screen.
    _ = c.g_timeout_add(1, refreshTimeoutCb, app);
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
