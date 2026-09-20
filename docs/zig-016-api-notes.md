# Zig 0.16.0 API notes (from M0 probes)

Recorded so later milestones don't re-derive these or write against remembered/wrong signatures. Every claim below was proven against a compiled, run probe in this repo's history, not read off docs alone.

## HTTP client (`std.http.Client`) — WORKS AS EXPECTED

0.16 reworked the client around the new `std.Io` interface. Construction pattern:

```zig
var threaded: std.Io.Threaded = .init(gpa, .{});
defer threaded.deinit();
const io = threaded.io();

var client: std.http.Client = .{ .allocator = gpa, .io = io };
defer client.deinit();
```

- `client.fetch(.{ .location = .{ .url = "..." }, .response_writer = &writer })` is the one-shot convenience API. It handles CA-bundle loading, TLS, and redirects internally.
- CA bundle is loaded lazily via `std.crypto.Certificate.Bundle.rescan`, which on Linux tries the standard distro paths in order and found `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem` (this system's actual bundle, reached via the `/etc/ssl/certs/ca-bundle.crt` symlink) with **zero configuration needed**.
- DNS resolution and the TLS handshake both work unmodified in a **fully static musl build** (`-Dtarget=x86_64-linux-musl`, `linkage` static by default for musl unless overridden). `ldd` confirms "not a dynamic executable"; the probe still completed a real HTTPS GET + JSON parse.
- `std.json.parseFromSlice(std.json.Value, gpa, body, .{})` works exactly as documented; `Parsed(T).deinit()` frees it.

**Confirmed working end-to-end**: HTTPS GET → system CA bundle → TLS 1.3 → JSON parse, both as a native glibc binary and as a static musl binary.

## No TLS session resumption — real, measured limitation

`std.crypto.tls.Client`'s handshake loop, on receiving a `new_session_ticket` handshake message, explicitly does nothing with it:

```zig
.new_session_ticket => {
    // This client implementation ignores new session tickets.
},
```

(`lib/std/crypto/tls/Client.zig`, in the `.handshake` branch of the record-processing switch.)

There is no session-ticket storage, no PSK/0-RTT support, nothing to hook. **Every connection in the respawn model pays a full TLS 1.3 handshake.** This is not optional or fixable at our layer without patching std — documented honestly in M7 rather than worked around by weakening verification.

## `zig build test --fuzz` — supported

`-ffuzz` / `-fno-fuzz` exist as flags on `zig test`/`zig build-exe`/`zig build`. Fuzz instrumentation is available for M7's decoder fuzzing (`mime.zig`'s RFC 2047 decoder, JSON parsing of untrusted header content).

## `@cImport` of GTK3 / gtk-layer-shell — BROKEN, upstream compiler bug, fallback in use

**This is the single biggest finding of M0.** `@cImport(@cInclude("gtk/gtk.h"))` (and transitively any GObject-family header, since the failure is in core `glib/gmacros.h`) either:

- dumps ~6000 translation errors (`unknown type name 'pragma'`, `unknown type name 'diagnostic'`), or
- **segfaults the compiler outright** (observed when attempting a `-D_Pragma(x)=` workaround).

Root cause (confirmed via web search against known Zig/Aro issues, not guessed): Zig 0.16.0 switched `translate-c` to the Aro C frontend, which has a confirmed bug mishandling macros that expand to **multiple consecutive `_Pragma(...)` invocations** — exactly GLib's `G_GNUC_BEGIN_IGNORE_DEPRECATIONS`:

```c
#define G_GNUC_BEGIN_IGNORE_DEPRECATIONS   \
  _Pragma ("GCC diagnostic push")          \
  _Pragma ("GCC diagnostic ignored \"-Wdeprecated-declarations\"")
```

This is pulled in unconditionally by `glib.h` → `gmacros.h`, so it affects **every** GTK/GLib/Gio program, not just ours, and not just gtk-layer-shell. The fix landed upstream in arocc (`Vexu/arocc#997`, "Fix macro expansion with multiple pragmas") but is **not present in the 0.16.0 release build** we installed.

### Resolution: hand-declared `extern` bindings instead of `@cImport`

This was already the plan's documented fallback, and it works cleanly with **zero compiler errors, zero crashes, zero struct-layout risk** — every GObject instance is an opaque pointer by design (that's the whole point of GObject's C ABI), so there is nothing for Zig to get wrong by not seeing the real struct definition. Verified with a real compiled probe:

- Opaque types (`pub const GtkWidget = opaque {};` etc.) for every widget/object type touched.
- `pub extern fn ...` prototypes for every GTK/GLib/Gio/gtk-layer-shell function called, matching signatures read directly from the system headers (not guessed).
- Enum values (`GTK_LAYER_SHELL_LAYER_TOP = 2`, `GTK_LAYER_SHELL_EDGE_RIGHT = 1`, `GTK_LAYER_SHELL_EDGE_TOP = 2`, `GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND = 2`, `G_APPLICATION_FLAGS_NONE = 0`) read directly from `/usr/include/gtk-layer-shell/gtk-layer-shell.h` and `/usr/include/glib-2.0/gio/gioenums.h`, not @cImport'd.
- Linking is unaffected: `mod.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .yes })` and `"gtk-layer-shell-0"` still resolve via pkg-config exactly as before — only the *header translation* path was broken, not linking.
- **Visually confirmed**: a real `GtkApplication` + `GtkWindow` was created, `gtk_layer_shell` calls anchored it top-right with the correct margins, and `grim` screenshot evidence shows the label rendering as a proper compositor-level overlay layer surface (on top of terminal content), at the expected screen position. Clean process exit (code 0) after `g_application_quit()`.

**Consequence for M1 onward**: `src/c.zig` (per the file layout) will contain these hand-declared bindings rather than an `@cImport` block. This is more code than one `@cImport` line, but it is a fixed, one-time cost — every subsequent milestone proceeds exactly as planned otherwise. `gtk3-devel` and `gtk-layer-shell-devel` stay useful for their headers-as-reference-material role (reading exact signatures/enum values) and for providing the unversioned `.so` symlinks the linker's `-l` flags need.

### Build API note (unrelated to the Aro bug, just a 0.16 API move)

`linkSystemLibrary` moved from `Compile` to `Module` in 0.16:

```zig
// 0.16: call on the module, not the executable
const mod = b.createModule(.{ ... });
mod.linkSystemLibrary("gtk+-3.0", .{ .use_pkg_config = .yes });
const exe = b.addExecutable(.{ .name = "...", .root_module = mod });
```

## Summary of decisions this feeds into M1+

| Area | Decision |
|---|---|
| HTTP/JSON | Use `std.http.Client` + `std.json` as originally planned; no `curl` fallback needed |
| Static musl build | Confirmed viable; use it for `waybar-gmail` as planned |
| TLS session resumption | Not available; M7 documents the ~1400 full-handshakes/day cost honestly |
| Fuzzing | `-ffuzz` available; use for M7 |
| GTK/layer-shell bindings | Hand-declared `extern` in `src/c.zig`, not `@cImport` |
