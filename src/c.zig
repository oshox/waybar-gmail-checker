//! Hand-declared extern bindings for GTK3 + GLib/GObject/Gio + gtk-layer-shell.
//!
//! Why hand-declared instead of @cImport: Zig 0.16.0's Aro C frontend has a
//! confirmed upstream bug (fixed later in arocc PR #997, not in 0.16.0)
//! that segfaults or dumps thousands of errors translating GLib headers
//! containing macros that expand to multiple back-to-back _Pragma(...)
//! statements (G_GNUC_BEGIN_IGNORE_DEPRECATIONS and friends, pulled in
//! transitively by every GObject-family header). See
//! docs/zig-016-api-notes.md for the full writeup and the probe that
//! proved this approach works.
//!
//! This is safe because the GTK3/GObject C ABI exposed here is just opaque
//! pointers-to-structs (GObject's whole design point) and plain function
//! pointers for signals -- there is no struct layout for Zig to get wrong,
//! with the sole exception of GList (a plain 3-pointer struct, frozen ABI,
//! declared exactly below). Every signature here was read directly from
//! the system headers under /usr/include/gtk-3.0 and /usr/include/glib-2.0,
//! not guessed or recalled from memory.

const std = @import("std");

// ---- opaque object types ----
pub const GObject = opaque {};
pub const GApplication = opaque {};
pub const GtkApplication = opaque {};
pub const GtkWidget = opaque {};
pub const GtkWindow = opaque {};
pub const GtkContainer = opaque {};
pub const GtkBox = opaque {};
pub const GtkLabel = opaque {};
pub const GtkListBox = opaque {};
pub const GtkListBoxRow = opaque {};
pub const GtkButton = opaque {};
pub const GtkScrolledWindow = opaque {};
pub const GtkEventBox = opaque {};
pub const GdkEvent = opaque {};

// ---- scalar typedefs ----
pub const gboolean = c_int;
pub const gint = c_int;
pub const guint = c_uint;
pub const gpointer = ?*anyopaque;
pub const GApplicationFlags = c_uint;
pub const G_APPLICATION_FLAGS_NONE: GApplicationFlags = 0;

pub const GtkOrientation = c_int;
pub const GTK_ORIENTATION_HORIZONTAL: GtkOrientation = 0;
pub const GTK_ORIENTATION_VERTICAL: GtkOrientation = 1;

pub const PangoEllipsizeMode = c_int;
pub const PANGO_ELLIPSIZE_END: PangoEllipsizeMode = 3;

pub const GtkLayerShellLayer = c_int;
pub const GTK_LAYER_SHELL_LAYER_TOP: GtkLayerShellLayer = 2;

pub const GtkLayerShellEdge = c_int;
pub const GTK_LAYER_SHELL_EDGE_RIGHT: GtkLayerShellEdge = 1;
pub const GTK_LAYER_SHELL_EDGE_TOP: GtkLayerShellEdge = 2;

pub const GtkLayerShellKeyboardMode = c_int;
pub const GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND: GtkLayerShellKeyboardMode = 2;

/// Read directly from /usr/include/gtk-3.0/gdk/gdkkeysyms.h -- a frozen
/// X11 keysym value, not something GTK versions change.
pub const GDK_KEY_Escape: guint = 0xff1b;

/// Read directly from /usr/include/gtk-3.0/gdk/gdktypes.h's GdkEventMask.
pub const GDK_ENTER_NOTIFY_MASK: gint = 1 << 12;
pub const GDK_LEAVE_NOTIFY_MASK: gint = 1 << 13;

pub const GConnectFlags = c_uint;
pub const GSourceFunc = *const fn (gpointer) callconv(.c) gboolean;
pub const GCallback = *const anyopaque;
pub const GClosureNotify = ?*const fn (gpointer, ?*anyopaque) callconv(.c) void;

/// Plain 3-pointer struct, frozen GLib ABI -- the one exception to
/// "everything here is opaque," and low-risk because it's exactly that:
/// three pointers, no bitfields, no padding surprises.
pub const GList = extern struct {
    data: gpointer,
    next: ?*GList,
    prev: ?*GList,
};

// ---- GObject / GApplication ----
pub extern fn g_object_unref(object: gpointer) void;
pub extern fn g_signal_connect_data(
    instance: gpointer,
    detailed_signal: [*:0]const u8,
    c_handler: GCallback,
    data: gpointer,
    destroy_data: GClosureNotify,
    connect_flags: GConnectFlags,
) c_ulong;
pub extern fn g_application_run(application: *GApplication, argc: c_int, argv: ?[*]?[*:0]u8) c_int;
pub extern fn g_application_quit(application: *GApplication) void;
pub extern fn g_timeout_add(interval: guint, function: GSourceFunc, data: gpointer) guint;
pub extern fn g_source_remove(tag: guint) gboolean;
pub extern fn g_list_free(list: ?*GList) void;

// ---- GtkApplication ----
pub extern fn gtk_application_new(application_id: [*:0]const u8, flags: GApplicationFlags) *GtkApplication;
pub extern fn gtk_application_window_new(application: *GtkApplication) *GtkWidget;

// ---- GtkWindow / GtkWidget / GtkContainer ----
pub extern fn gtk_window_set_title(window: *GtkWindow, title: [*:0]const u8) void;
pub extern fn gtk_window_set_default_size(window: *GtkWindow, width: gint, height: gint) void;
pub extern fn gtk_window_resize(window: *GtkWindow, width: gint, height: gint) void;
pub extern fn gtk_widget_get_preferred_height(widget: *GtkWidget, minimum_height: ?*gint, natural_height: ?*gint) void;
pub extern fn gtk_widget_show_all(widget: *GtkWidget) void;
pub extern fn gtk_widget_destroy(widget: *GtkWidget) void;
pub extern fn gtk_widget_set_size_request(widget: *GtkWidget, width: gint, height: gint) void;
pub extern fn gtk_widget_add_events(widget: *GtkWidget, events: gint) void;
pub extern fn gtk_widget_set_margin_start(widget: *GtkWidget, margin: gint) void;
pub extern fn gtk_widget_set_margin_end(widget: *GtkWidget, margin: gint) void;
pub extern fn gtk_widget_set_margin_top(widget: *GtkWidget, margin: gint) void;
pub extern fn gtk_widget_set_margin_bottom(widget: *GtkWidget, margin: gint) void;

pub extern fn gtk_container_add(container: *GtkContainer, widget: *GtkWidget) void;
pub extern fn gtk_container_remove(container: *GtkContainer, widget: *GtkWidget) void;
pub extern fn gtk_container_get_children(container: *GtkContainer) ?*GList;

// ---- GtkBox ----
pub extern fn gtk_box_new(orientation: GtkOrientation, spacing: gint) *GtkWidget;
pub extern fn gtk_box_pack_start(box: *GtkBox, child: *GtkWidget, expand: gboolean, fill: gboolean, padding: guint) void;
pub extern fn gtk_box_pack_end(box: *GtkBox, child: *GtkWidget, expand: gboolean, fill: gboolean, padding: guint) void;

// ---- GtkLabel ----
pub extern fn gtk_label_new(str: ?[*:0]const u8) *GtkWidget;
pub extern fn gtk_label_set_markup(label: *GtkLabel, str: [*:0]const u8) void;
pub extern fn gtk_label_set_line_wrap(label: *GtkLabel, wrap: gboolean) void;
pub extern fn gtk_label_set_ellipsize(label: *GtkLabel, mode: PangoEllipsizeMode) void;
pub extern fn gtk_label_set_xalign(label: *GtkLabel, xalign: f32) void;

// ---- GtkScrolledWindow / GtkListBox / GtkButton / GtkEventBox ----
pub extern fn gtk_scrolled_window_new(hadjustment: ?*anyopaque, vadjustment: ?*anyopaque) *GtkWidget;
pub extern fn gtk_scrolled_window_set_max_content_height(scrolled_window: *GtkWidget, height: gint) void;
pub extern fn gtk_scrolled_window_set_propagate_natural_height(scrolled_window: *GtkWidget, propagate: gboolean) void;
pub extern fn gtk_list_box_new() *GtkWidget;
pub extern fn gtk_button_new_with_label(label: [*:0]const u8) *GtkWidget;
pub extern fn gtk_event_box_new() *GtkWidget;

// ---- gtk-layer-shell ----
pub extern fn gtk_layer_init_for_window(window: *GtkWindow) void;
pub extern fn gtk_layer_set_layer(window: *GtkWindow, layer: GtkLayerShellLayer) void;
pub extern fn gtk_layer_set_anchor(window: *GtkWindow, edge: GtkLayerShellEdge, anchor_to_edge: gboolean) void;
pub extern fn gtk_layer_set_margin(window: *GtkWindow, edge: GtkLayerShellEdge, margin_size: gint) void;
pub extern fn gtk_layer_set_keyboard_mode(window: *GtkWindow, mode: GtkLayerShellKeyboardMode) void;
pub extern fn gtk_layer_set_namespace(window: *GtkWindow, name_space: [*:0]const u8) void;

// ---- GDK events ----
pub extern fn gdk_event_get_keyval(event: *const GdkEvent, keyval: *guint) gboolean;
