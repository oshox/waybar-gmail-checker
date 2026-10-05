# waybar-gmail-checker

A Waybar module that shows your Gmail unread count. Click the module for a
popup listing unread messages with previews and per-message mark-read /
archive / delete actions; click a message to open it in Gmail; double-click
the module to open the inbox.

Written in Zig. See [`docs/zig-016-api-notes.md`](docs/zig-016-api-notes.md)
for the design rationale (why two binaries, why a static musl build, why
GTK bindings are hand-declared) and a running log of Zig 0.16 API quirks
found along the way.

## How it's built

- **`waybar-gmail`** -- fully static (musl), zero dynamic linking. This is
  what waybar re-runs on every poll interval, so its only job is to make
  one cheap Gmail API call and print a JSON status line; it never links
  GTK.
- **`waybar-gmail-popup`** -- native, links GTK3 + gtk-layer-shell. Spawned
  only when you click the module.

## Setup

### 1. Install Zig 0.16.0 or newer

```sh
curl -LO https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
tar -xJf zig-x86_64-linux-0.16.0.tar.xz -C ~/.local/opt/
ln -sf ~/.local/opt/zig-x86_64-linux-0.16.0/zig ~/.local/bin/zig
```

(Adjust the archive name for your architecture -- see
[ziglang.org/download](https://ziglang.org/download/).)

### 2. Create a Google Cloud OAuth client

This is a one-time, ~5 minute setup. You need your own client because
Google requires every app to have one; it does not mean you're sending
your mail anywhere except directly to Google's own API.

1. Go to the [Google Cloud Console](https://console.cloud.google.com/)
   and create a new project (or pick an existing one).
2. **APIs & Services → Library**: search for "Gmail API" and enable it.
3. **APIs & Services → OAuth consent screen**: choose **External** (unless
   you have a Google Workspace org and want **Internal**), fill in the
   required fields (app name, your email), and add your own Google
   account under **Test users** -- while the app is in "Testing" status,
   only test users can authenticate, which is exactly what you want for a
   personal tool.
4. **APIs & Services → Credentials → Create Credentials → OAuth client
   ID**. Application type: **Desktop app**. Name it anything.
5. Download the resulting JSON (the "Download JSON" button on the
   credentials page) and save it as:
   ```
   ~/.config/waybar-gmail/client_secret.json
   ```
   `install.sh` will tell you if this file is missing. Its permissions
   should be `600` (owner read/write only); the app doesn't require this,
   but there's no reason for it to be readable by anyone else either.

The scope this project requests is
`https://www.googleapis.com/auth/gmail.modify` -- read, label changes
(mark-read, archive), and moving to trash. It deliberately does **not**
request permanent-delete permission; "delete" in the popup moves a
message to Trash, exactly like clicking delete in Gmail's own web UI.

### 3. Build and install

```sh
./install.sh
```

This builds both binaries, installs them to `~/.local/bin`, sets up
`~/.config/waybar-gmail/`, and merges the module's styling into
`~/.config/waybar/style.css` (with a timestamped backup first). It prints
the one thing it doesn't do automatically: adding the module block to
`~/.config/waybar/config.jsonc`, since that file is hand-maintained and
splicing JSON into someone else's comments/formatting programmatically is
more likely to mangle it than help. Copy the printed snippet (also at
[`waybar/config-snippet.jsonc`](waybar/config-snippet.jsonc)) into your
config, then reload waybar:

```sh
pkill -x -SIGUSR2 waybar
```

(`-x` matches the process name exactly. Without it `pkill` also matches
`waybar-gmail` and `waybar-gmail-popup`, and the signal would terminate an
open popup.)

### 4. Authenticate

```sh
waybar-gmail auth
```

Opens your browser for Google's consent screen. Once you approve, the
module should start showing your unread count within a few seconds
(or immediately -- click the module, or send waybar the refresh signal:
`pkill -x -RTMIN+9 waybar`).

## Prebuilt binaries (bootc and other images)

CI builds and tests both binaries against Fedora 44 and publishes them as a
`FROM scratch` image, `ghcr.io/oshox/waybar-gmail-checker`, containing just
the two files in `/usr/bin`. `latest` tracks `main`; every build is also
tagged `sha-<commit>`, and `v*` git tags are published under their own name.
To bake the binaries into another image:

```dockerfile
COPY --from=ghcr.io/oshox/waybar-gmail-checker:latest /usr/bin/waybar-gmail /usr/bin/waybar-gmail-popup /usr/bin/
```

`waybar-gmail` is static. `waybar-gmail-popup` needs Fedora 44's GTK3 and
gtk-layer-shell, and both need `secret-tool` (libsecret), `xdg-open` and
`pkill` at runtime. With the binaries in `/usr/bin`, the waybar module
should use the bare command names, as in
[`waybar/config-snippet.jsonc`](waybar/config-snippet.jsonc); a dev install
in `~/.local/bin` (from `./install.sh`) then still takes precedence on `PATH`.

## Configuration

`~/.config/waybar-gmail/config.json` (optional -- sensible defaults apply
if it's absent or any field is missing):

```json
{
  "max_messages": 15,
  "double_click_ms": 350
}
```

- `max_messages` -- how many unread messages the popup fetches previews
  for.
- `double_click_ms` -- the maximum gap between two clicks that counts as
  a double-click (opens the inbox instead of the popup). If double-clicks
  aren't being recognized reliably, raise this a little.

There is deliberately no polling-interval setting here: that's controlled
entirely by the `interval` field of the `custom/gmail` block in waybar's
own `config.jsonc`.

## Troubleshooting

**Module shows nothing / an error color.** Run `waybar-gmail status | jq
.` directly to see the JSON it's producing and the `class` field
(`unread`, `read`, `error`, `unauthenticated`). Error details are printed
to stderr, which waybar normally swallows -- run it in a terminal to see
them.

**`class: "unauthenticated"`.** Either `client_secret.json` is missing
(see Setup step 2), or `waybar-gmail auth` hasn't been run yet (or its
token expired and the stored refresh token is invalid, e.g., you revoked
this app's access in your Google Account settings). Re-run `waybar-gmail
auth`.

**Double-click opens the popup instead of the inbox (or vice versa).**
Raise or lower `double_click_ms` in `~/.config/waybar-gmail/config.json`.

**Popup doesn't open at all.** Check that `~/.local/bin` is on `PATH` --
`click.zig` spawns `waybar-gmail-popup` by bare name via `PATH` lookup, and
the waybar module snippet runs `waybar-gmail` by bare name too, so both
need to be findable that way. Run `waybar-gmail-popup` directly in a
terminal to see any startup error.

**After an `rpm-ostree upgrade` (or similar atomic-OS update).** If you
built on an rpm-ostree-based system (Fedora Silverblue/Sericea/Kinoite
etc.) and layered `gtk3-devel`/`gtk-layer-shell-devel` to build this
project, a base OS upgrade can drop layered packages if they're not
re-applied to the new deployment. You won't need to *rebuild* the
binaries (they're already compiled), but if you ever need to rebuild
after such an upgrade, re-layer those two packages first:
```sh
rpm-ostree install gtk3-devel gtk-layer-shell-devel
```

## Development

```sh
zig build test    # unit tests
zig build         # both binaries, into zig-out/bin/
```

To reproduce what CI builds (both binaries compiled and the unit tests run
inside a Fedora 44 container, using a throwaway keyring from
[`ci/test.sh`](ci/test.sh)):

```sh
podman build -t waybar-gmail-checker:local .
```

Every network call goes through a fixture-mode seam: set
`WAYBAR_GMAIL_FIXTURE=/path/to/fixtures` and every Gmail API call reads
canned JSON from that directory instead of the network -- see
[`fixtures/README.md`](fixtures/README.md) for the format and the
committed fixture set (deliberately including RFC 2047-encoded headers,
emoji, RTL text, an oversized subject line, and malformed UTF-8). This is
what makes the whole pipeline -- `status`, the popup, actions -- testable
without a live Google account:

```sh
WAYBAR_GMAIL_FIXTURE=$PWD/fixtures ./zig-out/bin/waybar-gmail status | jq .
```
