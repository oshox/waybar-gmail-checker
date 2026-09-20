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

## `std.fs.Dir` moved to `std.Io.Dir` -- every operation now takes an `io: Io`

Confirmed while writing M1's `cache.zig`. `std.fs` is now a thin, mostly-deprecated shim (`fs.zig` is ~16 lines); the real type is `std.Io.Dir`, and essentially every method (`createFile`, `openFile`, `rename`, `deleteFile`, `stat`, `createDirPathOpen`, `iterate`, ...) takes an `io: Io` parameter alongside `self`. Likewise `std.fs.File` doesn't exist -- it's `std.Io.File`, with `.stdout()`/`.stderr()`/`.stdin()` and a `writer(io, buffer)` that also needs `io`. `std.debug.print` still needs no `Io` from the caller (it manages stderr access internally), so it's the right choice for simple CLI usage/error output that happens before any real I/O setup.

`Dir.Permissions` is `enum(std.posix.mode_t) { default_file = 0o666, default_dir = 0o777, _, }` with `.fromMode(0o600)` to build an arbitrary mode -- used throughout for the "0600 on every private file" requirement.

## New `pub fn main(init: std.process.Init) ...` entry-point convention

0.16 added an alternative main signature the runtime detects via `@typeInfo`: `pub fn main(init: std.process.Init) u8` (or `!void`, etc.). `init` bundles:

- `init.io: Io` -- a ready `Io.Threaded` instance, so subcommands never need to construct their own.
- `init.gpa: Allocator` -- **automatically leak-checked in debug builds**. This satisfies M7's "every subcommand runs under a leak-detecting allocator" requirement for free, with no extra wiring.
- `init.arena: *std.heap.ArenaAllocator` -- process-lifetime scratch allocator.
- `init.minimal.args: std.process.Args` -- `args.iterate()` gives an `Iterator` with `.next() ?[:0]const u8` (Linux path needs no allocator).
- `init.environ_map: *Environ.Map` -- parsed environment.

`src/main.zig` and `src/popup_main.zig` both use this convention now instead of the old plain `fn main() u8` + manually reading `std.os.argv`/env.

## Confirmed upstream bug: `Dir.iterate()` / `dirReadLinux` panics on Linux

Found while testing `cache.zig`'s atomic-write cleanup, then reproduced in complete isolation (a freshly created, otherwise-untouched directory, zero prior operations on it) and independently corroborated by other projects hitting the identical panic (`ziyle` `sigil` project's CI, `chung-leong/zigar` issue #1081 hitting the same `errnoBug`/BADF pattern from a different call site) -- this is a real regression in `std.Io.Threaded`'s Linux directory-reading path, not anything specific to our usage:

```
thread N panic: programmer bug caused syscall error: BADF
.../std/Io/Threaded.zig: posixSeekTo(dr.dir.handle, 0) catch |err| switch (err) {
.../std/Io/Threaded.zig: dirReadLinux
.../std/Io/Dir.zig: Reader.read -> Iterator.next
```

Every call path through `Dir.iterate()` + `Iterator.next(io)` hits this, including the simplest possible case (`var it = dir.iterate(); try it.next(io);` on an empty dir, no prior writes). `Dir.walk`/`walkSelectively` are built on the same reader and are presumably equally affected (not independently verified here, since nothing in this project needs them).

**Resolution: don't use directory iteration.** Nothing in `cache.zig`'s actual functionality needs it -- the only place it showed up was a test asserting "no leftover temp file," which was rewritten to predict the exact temp filename (by exposing the random suffix as a parameter to an internal `atomicWriteWithSuffix`) and check for its absence directly with `readFile`/`FileNotFound`, rather than listing the directory. If a later milestone ever seems to need directory enumeration (none currently planned), re-probe this first rather than assuming it's fixed.

## Miscellaneous API renames found while writing M2

Small, easy to trip over, listed here so they're not re-discovered the hard way:

- `std.process.Child.Term` variants are lowercase now: `.exited`, `.signal`, `.stopped`, `.unknown` (not `.Exited`).
- `std.mem.trimRight` is gone; it's `std.mem.trimEnd` (and `trimStart`/`trim`).
- `std.Build.path()` panics on an absolute path (`"is expected to be relative to the build root"`); use `.{ .cwd_relative = "/abs/path" }` as the `LazyPath` instead.
- `std.http.Client.fetch`'s `method`/`extra_headers`/`payload`/`response_writer` fields work as expected once you're past the `Io` construction (see the M0 probe notes above) -- confirmed again in `http.zig` and `oauth.zig`'s token-endpoint calls.
- `std.Uri.percentDecodeInPlace(buf)` decodes in place and returns a **shorter** slice of the same buffer. That returned slice cannot be freed on its own -- its length no longer matches the original allocation's, and the debug allocator correctly flags this (`Invalid free`, canary mismatch) if you try. Dupe the decoded result into a fresh allocation before freeing the scratch buffer. The same general lesson applies anywhere a sentinel-terminated allocation (`[:0]u8` from e.g. `Dir.realPathFileAlloc`) gets coerced to a plain slice and stored somewhere it will later be freed from -- free it through its *original* type, or dupe first.
- `std.Io.net.Socket.address` already holds the real bound address/port after `IpAddress.listen(...)` with port 0 requested -- no `getsockname`-equivalent call needed to discover an ephemeral port.
- `Io.Timestamp.now(io, .real).toSeconds()` for a unix timestamp.
- `std.process.spawn(io, .{ .argv = ..., .stdin = .pipe, .stdout = .pipe, ... }) !Child`, with `child.stdin.?`/`child.stdout.?` as ordinary `Io.File` values (same reader/writer pattern as everything else) and `child.wait(io) !Term`.

## `xdg-open` can block for a long time -- don't wait for it

Not a Zig API issue, but a real bug caught during M4's live testing: the
initial `openInBrowser` helper (used by both `oauth.runConsentFlow` and
`click`'s double-click handler) spawned `xdg-open` and called `child.wait(io)`
on it. On this system that blocked for tens of seconds (observed directly:
`ps` showed `/usr/bin/sh /usr/bin/xdg-open ...` still running well after the
browser tab had already opened), apparently down to mime-association/D-Bus
lookup overhead inside the `xdg-open` shell script itself, not anything
about the URL or the browser.

`click`'s entire point is to feel instant, so waiting on `xdg-open` is
never acceptable there, and there's no good reason for `runConsentFlow` to
wait on it either (the URL is already printed as a fallback regardless).
Fixed by not waiting at all: spawn and return immediately. The child is
reparented to init once we exit and reaped normally -- no zombie risk,
and we don't need its exit status since we can't act on it anyway.

## Summary of decisions this feeds into M1+

| Area | Decision |
|---|---|
| HTTP/JSON | Use `std.http.Client` + `std.json` as originally planned; no `curl` fallback needed |
| Static musl build | Confirmed viable; use it for `waybar-gmail` as planned |
| TLS session resumption | Not available; M7 documents the ~1400 full-handshakes/day cost honestly |
| Fuzzing | `-ffuzz` available; use for M7 |
| GTK/layer-shell bindings | Hand-declared `extern` in `src/c.zig`, not `@cImport` |
| Filesystem access | `std.Io.Dir`/`std.Io.File`, not `std.fs`; thread `io` through everywhere |
| Process entry point | `pub fn main(init: std.process.Init) u8`, using `init.io`/`init.gpa`/`init.minimal.args` |
| Directory iteration | Avoid entirely (`Dir.iterate`/`walk` hit a confirmed upstream Linux panic); design around predictable filenames instead |
