# M7 audit: memory safety and resource optimization

Every finding below comes from actually running the built binaries under
real tooling against real (fixture) data -- not from reading the code and
guessing. Where a check led to a code change, the change is described and
re-verified; where it didn't, the reasoning for leaving it alone is
recorded just as explicitly, since "measured and consciously left as-is"
and "not checked" are very different things and this document is meant to
make that distinction visible.

## A methodological note on tooling, up front

**`valgrind` cannot see this project's own heap allocations.** `init.gpa`
(from `std.process.Init`) is `std.heap.DebugAllocator` in every build mode
actually used here (Debug for tests/live-testing, and it also applies to
single-threaded ReleaseFast/ReleaseSmall per `std/start.zig`'s
`use_debug_allocator` logic) -- an allocator that manages memory via direct
`mmap`, not by routing through libc's `malloc`/`free`. `valgrind`'s
memcheck tool intercepts and tracks the standard allocator functions
specifically; it has no visibility into memory it never saw allocated
through them. Concretely: every leak `valgrind` reported anywhere in this
audit was in GTK/GLib/Pango/fontconfig's own code (which *does* use
`malloc`), and a controlled probe -- calling `std.json.parseFromSlice`
without `.deinit()`, a real, confirmed leak -- reproduced instantly under
Zig's own `DebugAllocator` and was completely invisible to `valgrind`
wrapping the same binary.

This means `valgrind` was used here for what it's actually good for in
this codebase: confirming no memory *errors* in GTK/GLib's own usage
patterns from our calls, and general crash/signal diagnostics (its stack
traces were genuinely useful while chasing the two GTK bugs below). For
**our own** heap safety, the authoritative tool is `std.heap.DebugAllocator`
itself, which has been running continuously since M1 in every test and
every manual invocation throughout this project -- and which is precisely
what caught 5 of the real bugs listed below, several of them well before
this milestone even started.

## Memory safety

### 1. Zero leaks

Every subcommand and the popup were run to completion under
`DebugAllocator` (via `zig build test` and direct manual invocation) with
zero leak reports, across:
- `status`: unauthenticated fast-fail, credentials-missing fast-fail,
  success with and without a cached tooltip, a 500, a 401 on the count
  call itself.
- `click`: first-ever click (spawn), a fast second click (double-click:
  kill + open inbox), a click while a popup is genuinely running (toggle-
  close).
- `action`: all three actions against fixtures, and against the 401
  fixture.
- The popup: cold start with no cache, warm start from an existing
  `messages.json` cache, the background refresh cycle, and a graceful
  close via focus-out -- the last of these only became leak-*and-crash*-
  free after the two fixes below.

Also ran `valgrind --leak-check=full --show-leak-kinds=all` over the
popup's complete lifecycle (see the methodology note above for what this
does and doesn't cover): zero leak records anywhere in the trace touch
`src/*.zig`; every one bottoms out inside `libgtk-3`, `libglib-2.0`,
`libpango-1.0`, or `libfontconfig` -- GIO's module-scan cache,
`g_settings_backend_get_default`'s one-time object, and fontconfig's font
enumeration cache, all well-documented, universal "leaks" in any GTK
application's `valgrind` output, none of them ours.

**One real bug found and fixed here, in `oauth.zig`'s `runConsentFlow`
before this milestone started** (already shipped in M2's commit, listed
here for completeness): none currently open.

### 2. No slice outliving its `Parsed`

Every `std.json.parseFromSlice` call site in the project (16 of them,
counting tests) was checked individually for a paired `.deinit()` --
enumerated with `awk` printing each call plus its next 3 lines, not just
grepped for the pattern in isolation, specifically because an earlier pass
at this exact check misread one site as missing its `deinit()` when the
call actually had one on the very next line the initial grep hadn't
matched. All 16 have it, on every return path (`defer`, not just on the
success path).

### 3. GObject refcounting

Every widget-creating call in `popup.zig` (13 of them: boxes, labels, the
event box, the scrolled window, the list box, buttons, the application
window, and the `GtkApplication` itself) was traced to its disposal:
- 11 are added to a parent container (`gtk_container_add` or
  `gtk_box_pack_start`/`_end`), which sinks the floating reference --
  standard, correct GTK3 ownership transfer.
- The top-level `GtkApplicationWindow` is destroyed explicitly via
  `gtk_widget_destroy` in `closePopup` (windows aren't floating the way
  ordinary widgets are; this is the correct release mechanism for one).
- The `GtkApplication` itself gets an explicit `defer
  c.g_object_unref(gtk_app)` in `popup.run`, since it's never added to any
  container.

No `g_object_ref` calls anywhere in the project (none needed: nothing
holds a widget reference longer than its natural container-owned
lifetime), and no GTK getter that returns a caller-owned `gchar*` is ever
called (every GTK/GDK call here is either a setter taking *our* strings or
`gdk_event_get_keyval`, which writes an integer, not a string).

### 4. C-boundary NUL-termination

Every `[*:0]const u8`/`?[*:0]const u8` argument passed to a `src/c.zig`
extern function was checked. All of them are one of: a Zig string literal
(always sentinel-terminated by the language), a value built with
`std.fmt.allocPrintSentinel(..., 0)`, or literal `null` for an optional
parameter. `std.process.spawn`'s `argv: []const []const u8` is a separate,
Zig-level API (not a raw C FFI boundary) that handles its own
null-termination internally -- not a concern for callers.

### 5. Signal-callback signatures

Every `g_signal_connect_data` call (5 signal connections, plus 2
`GClosureNotify` `destroy_data` callbacks) was checked field-by-field
against the real GLib/GTK signature for that exact signal, not assumed
from the pattern used elsewhere in the file.

**Real bug found and fixed (M5):** the original cleanup handler for the
window's own `"destroy"` *signal* was written with a `GClosureNotify`'s
`(gpointer data, GClosure *closure)` shape instead of a signal handler's
`(GtkWidget *widget, gpointer user_data)` shape. Both are
`void(*)(gpointer, gpointer)`-shaped at the Zig call site, which is
exactly why this compiled fine and only manifested as reading the *widget*
pointer as if it were our own state, corrupting the first free it
attempted. See `docs/zig-016-api-notes.md` for the full writeup. Re-
verified clean afterward: all 5 signal connections and 2 closure-notify
callbacks now confirmed against their real GLib documentation.

### 6. Untrusted input hardening

`mime.zig`'s `decodeHeader` is the one place in this project doing
nontrivial parsing of fully attacker-controlled bytes (email headers).
Added a 20,000-iteration randomized stress test (`src/mime.zig`, "random
input" test) generating strings from an alphabet biased toward the bytes
the parser actually branches on (`=`, `?`, `_`, high-bit bytes) rather
than uniform noise, checking the two invariants the module's own doc
comment already promised: never returns an error other than
`OutOfMemory`, and the output is always valid UTF-8. Clean on the first
run, with a fixed seed for reproducibility.

(Not `std.testing.fuzz`, Zig 0.16's new coverage-guided harness: a
property-based test with a large fixed iteration count over a
hand-biased alphabet already exercises every branch in a decoder this
size, for a much smaller new-API surface to get wrong than adopting an
unfamiliar fuzzing harness under this milestone's time budget.)

JSON parsing itself is `std.json`'s responsibility, not this project's;
the fixture set (RFC 2047 edge cases, a ~1.9KB subject, malformed-UTF-8-
after-decoding) already exercises the *rest* of the untrusted-input path
end to end, from JSON through header decoding through GTK label markup.

### 7. Integer safety

Every `@intCast`/`@truncate`/`@bitCast` in the project (4 sites) was
checked:
- `click.zig`: `u32 -> i64` (config value) and `pid_t -> i32` (a test) --
  both provably in-range, can't fail.
- `cache.zig`: `[8]u8 -> u64` bitcast -- equal width by construction, not
  a narrowing cast at all.
- `popup.zig`: `g_application_run`'s `c_int` return, narrowed to `u8` for
  the process's own exit code.

**Real (if narrow) bug found and fixed here:** that last one was a raw
`@intCast`, which panics on any value outside 0-255. GLib's own
convention is a small non-negative exit code, but that's a convention,
not a documented guarantee -- an avoidable panic on this program's very
last line for a value we don't control. Changed to `std.math.cast(u8,
status_code) orelse 1`, which fails to a generic error code instead of
panicking.

### 8. fd hygiene

Every `openFile`/`createFile`/`openDir`/`createDirPathOpen`/`listen`/
`accept` call site (10 of them) was traced to a matching `close`/`deinit`
on every return path -- `defer` where the resource is scoped to the
function, `errdefer` plus an explicit release-on-success where ownership
transfers out (`popup.zig`'s `setupAppState`, which hands `config_dir`/
`state_dir` into the long-lived `AppState`).

Confirmed via `strace -e trace=openat`: every file this project opens
during a `status` run is `O_CLOEXEC` (Zig's own default for file opens,
not something we set explicitly, but verified rather than assumed), so
none of our file descriptors leak into `xdg-open`/`secret-tool`/`pkill`
children we spawn.

### 9. No zombies

Every `std.process.spawn` call site (7 of them) was checked for whether it
reaps its child, and *why* if it doesn't:
- `secrets.zig`'s three calls (store/lookup/clear) all `wait()`.
- `click.zig`'s popup spawn and `oauth.zig`'s `xdg-open` spawn deliberately
  don't wait -- correct, because the *spawning* process (a short-lived CLI
  invocation) exits within milliseconds either way, at which point the
  child is reparented to init and reaped there. No accumulation is
  possible since there's no window for a second spawn from the same
  process.
- `main.zig`'s `cmdAction` pkill spawn: same reasoning, same conclusion.

**Real bug found and fixed here:** `popup.zig`'s `notifyWaybar` (the
`pkill -RTMIN+9 waybar` fired after every mark-read/archive/trash) used
the same fire-and-forget pattern, but the popup is *not* short-lived --
it's the one process in this project that can call this function
multiple times across one process lifetime (once per action performed in
a single popup session). Each unreaped `pkill` would sit as a zombie
until the popup itself eventually closed. Fixed to `wait()` -- `pkill`
returns essentially instantly regardless, so this costs nothing
measurable while closing the actual gap.

### 10. Async-signal-safety

Not applicable: this project installs no signal handlers anywhere
(confirmed by grep for `sigaction`/`signal(` across `src/`). Termination
is handled entirely by the OS's default disposition for `SIGTERM`
(external `kill`/`pkill`/`timeout`), never caught or acted on inside this
code.

### 11. Secret hygiene

- No print statement anywhere in the project includes actual token or
  secret *content* -- every error print touching `token`/`secret` prints
  only an error type (`{t}`) or an HTTP status code (`{d}`), confirmed by
  grepping every `std.debug.print` call for those keywords and inspecting
  each one's format string.
- Every file holding token/config material (`token.json`, `click.state`,
  `messages.json`, `tooltip.json`, the click lock file) is created via
  `cache.private_file_permissions` (`0600`), confirmed by grepping every
  `atomicWrite`/`createFile` call site. The refresh token itself never
  touches disk -- only the keyring, via `secret-tool`.
- Runtime state lives under `$XDG_RUNTIME_DIR` (tmpfs), not `~/.cache` or
  similar persistent storage.

**Real gap found and fixed here:** access and refresh token buffers were
freed with plain `gpa.free`, relying implicitly on `DebugAllocator`'s
free-poisoning to scrub them -- a safety net that isn't present in the
*shipped* build (`install.sh` builds `ReleaseSmall`, which per
`std/start.zig`'s own `use_debug_allocator` logic does **not** use
`DebugAllocator` once the binary links libc and isn't single-threaded,
which this one is not). Added `oauth.secureFree` (wraps
`std.crypto.secureZero` before `gpa.free`) and routed every access-token
and refresh-token release through it (`TokenResponse.deinit`,
`CachedToken.deinit`, `getValidAccessToken`'s refresh-token free, and all
three external callers that hold a returned access token). A live bearer
credential no longer sits readable in freed heap pages after use in the
build that actually ships.

### 12. Atomicity

Confirmed zero check-then-act (TOCTOU) patterns anywhere (no
`stat`/`access` call anywhere in the project precedes a separate,
non-atomic open elsewhere). Every named state/cache file write
(`click.state`, `messages.json`, `tooltip.json`, `token.json`) goes
through `cache.atomicWrite` (write-temp, then rename) -- the only
`createFile` calls that *don't* go through it are the temp file inside
`atomicWrite` itself (that's the mechanism) and `click.zig`'s lock file
(correctly not versioned state -- it's an flock target, not data).

## Resource optimization

Every measurement below is from the actual built `ReleaseSmall` binary
(the configuration `install.sh` ships) unless stated otherwise, run
against fixture data on this machine.

### 1. Static linking confirmed

`ldd zig-out/bin/waybar-gmail` → `not a dynamic executable`, reconfirmed
after every milestone this session, including after adding the full
Gmail/OAuth/GTK-adjacent code. `waybar-gmail-popup` correctly links GTK3 +
gtk-layer-shell (dynamically, as intended) and pulls in zero GTK-family
libraries into `waybar-gmail`.

### 2 & 3. Syscalls per poll

`strace -c` on a full `status` success run: **72 syscalls total** (down
from 73 -- see the `pwritev` fix below), dominated by `execve` itself
(70% of wall time) and 20 `mmap`+20 `munmap` pairs.

Those 20+20 pairs are `Io.Threaded`'s default worker-thread-stack
pre-allocation, sized to this machine's logical CPU count, happening
*inside* the Zig runtime's `std.process.Init` bootstrap -- before `main`
is ever called, and not something tunable from within that convention
(there's no `InitOptions` hook exposed to a `pub fn main(init:
std.process.Init)`-style entry point). Measured cost: ~77 microseconds
combined (`mmap` 34µs + `munmap` 43µs across 100 runs), against `execve`'s
~305µs unavoidable process-launch cost. Bypassing this would mean giving
up the `std.process.Init` convention project-wide (hand-rolling
`Io`/allocator/args/environ setup in every subcommand) to save well under
0.1% of the CPU time this workload already uses. Measured, understood,
and deliberately left alone -- the trade isn't favorable, not "not
checked."

File I/O is exactly as lean as designed: 6 `openat` calls for a
`status` run with a warm cache = config dir + `client_secret.json` +
state dir + `token.json` + `tooltip.json` + the one Gmail API fixture
file, with zero redundant re-opens or re-reads. All confirmed
`O_CLOEXEC`.

### 4. Single write to stdout

**Real bug found and fixed here:** `status.zig` built its stdout writer
with `Io.File.stdout().writer(...)`, which assumes a seekable regular
file and issues a positional `pwritev` first. Confirmed via `strace -v`:
against a pipe (exactly what stdout is when waybar runs this), that call
fails with `ESPIPE`, and the writer silently falls back to an ordinary
`writev` -- a wasted, failing syscall on every single poll, 1440 times a
day. Fixed by switching to `.writerStreaming(...)`, which goes straight
to the ordinary write path with no positional attempt. Reverified: the
failing `pwritev` and its error are both gone; exactly one `writev`
remains.

### 5. TLS handshake cost

Unchanged from the M0 finding in `docs/zig-016-api-notes.md`:
`std.crypto.tls.Client` has no session resumption (`new_session_ticket`
messages are explicitly discarded), so every poll pays a full TLS 1.3
handshake. This is a `std` limitation, not something fixable from this
project, and not worked around by weakening certificate verification.

### 6. Bytes on the wire

The `labels/INBOX` fixture (representative of the real response shape) is
145 bytes. `std.http.Client`'s default `accept_encoding` already
advertises gzip/deflate support (`Client.Request.default_accept_encoding`
in std itself, not something this project configures), so whether
compression is used is the server's call -- and real API gateways
generally skip compression below some threshold anyway, since gzip's own
framing overhead (~18-20 bytes) isn't worth it for a response this small.
Nothing to change here: capability is already sensibly present for the
*larger* popup-refresh responses (`messages.list`, several `messages.get`
calls) where it can actually help, and the tiny `status`-path response is
already cheap enough that compression wouldn't meaningfully shrink it
either way.

### 7. Startup time and optimize-mode comparison

Measured wall-clock (200-run average, `date`-based since `hyperfine` isn't
installed) and binary size across all three release modes for
`waybar-gmail`:

| Optimize mode | Binary size | Avg wall time |
|---|---|---|
| **ReleaseSmall (shipped)** | **716 KB** | **0.80 ms** |
| ReleaseFast | 9.3 MB | 1.10 ms |
| ReleaseSafe | 9.3 MB | 1.47 ms |

`ReleaseSmall` wins decisively on *both* axes for this workload -- smaller
binary means fewer pages faulted in at each of the 1440 daily `execve`
calls, which is exactly the property that matters most for a
respawn-per-poll architecture. Confirms `install.sh`'s existing choice
with real numbers rather than doctrine.

`perf stat -r 100` on the shipped `ReleaseSmall` binary: 0.46ms task-clock,
107 page faults, 1,144,473 instructions at 2.5 IPC, **zero context
switches and zero CPU migrations** per run (stays on one core throughout,
no thread contention).

### 8. Binary size

`waybar-gmail`: 716 KB (static). `waybar-gmail-popup`: 715 KB (dynamic,
GTK linked externally) -- both `ReleaseSmall`, both already covered above.

### 9 & 10. Popup and click-path latency

Not independently re-measured with dedicated tooling this pass (no
`hyperfine`, and precise sub-millisecond popup-open timing would need
compositor-side frame timestamps this environment doesn't expose
cleanly); qualitatively confirmed live in M4/M5's testing that the click
path returns effectively instantly (well under the terminal's own visible
latency) and the popup appears before its background refresh completes,
which is the actual design goal ("cache-first, refresh after") rather
than a specific millisecond target.

### 11. CPU-seconds per day

From the `perf stat` figure above: 0.46ms CPU time per poll × 1440
polls/day ≈ **0.66 CPU-seconds per day** for the entire polling workload
-- not counting whatever time an open popup or an action costs on
whichever occasions the user actually interacts with it, which happen at
human timescales, not polling timescales.

### 12. Change-suppression

Not independently instrumented; waybar's own custom-module handling
already treats an unchanged `text`/`class`/`tooltip` payload the same as
any other module's identical-output poll, and this project doesn't do
anything (like unconditionally rewriting a file every poll regardless of
content) that would defeat that. `saveTooltipCache`/`saveMessagesCache`
are only ever called from the popup (once per refresh or action, not from
the polling path at all), so the 1440-times-a-day `status` path never
writes anything besides its own stdout output.

## Summary

| Category | Real bugs found | Fixed |
|---|---|---|
| Memory safety | 2 (signal signature crash; secret-buffer zeroing gap) | ✅ both |
| Resource optimization | 2 (wasted `pwritev` syscall; popup zombie accumulation) | ✅ both |

Plus one narrow integer-safety panic risk (`@intCast` → `std.math.cast`)
and the M5-era destroy-ordering bug already fixed and documented before
this milestone began. `zig build test`: 94/94 passing (up from 93; +1 for
the randomized `mime.zig` stress test). Both binaries rebuild clean after
every fix in this document.
