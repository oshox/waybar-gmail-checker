#!/usr/bin/env bash
# Builds waybar-gmail + waybar-gmail-popup and installs them, plus the
# supporting config. Safe to re-run any time (e.g. after `git pull`) --
# every step here either overwrites its own prior output or checks first.
#
# What this script does NOT touch: your waybar config.jsonc. Merging a
# module into a hand-maintained JSONC file (comments, specific ordering,
# trailing commas) programmatically is exactly the kind of edit that's
# easy to get subtly wrong for someone else's file -- this prints the
# snippet and exact instructions instead. style.css is different: adding
# a few new CSS selectors that don't already exist is safe and additive,
# so that part *is* automated (with a timestamped backup first).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
APP_CONFIG_DIR="$HOME/.config/waybar-gmail"
WAYBAR_CONFIG_DIR="$HOME/.config/waybar"
STYLE_FILE="$WAYBAR_CONFIG_DIR/style.css"

log() { printf '==> %s\n' "$1"; }
warn() { printf 'warning: %s\n' "$1" >&2; }

log "Checking for zig..."
if ! command -v zig >/dev/null 2>&1; then
    echo "error: zig not found on PATH." >&2
    echo "       Install Zig 0.16.0 or newer -- see README.md for the recommended" >&2
    echo "       (official static tarball) install method." >&2
    exit 1
fi
ZIG_VERSION="$(zig version)"
log "Found zig $ZIG_VERSION"

log "Building waybar-gmail and waybar-gmail-popup (ReleaseSmall)..."
cd "$SCRIPT_DIR"
zig build -Doptimize=ReleaseSmall

log "Running the test suite before installing anything..."
zig build test

log "Installing binaries to $BIN_DIR..."
mkdir -p "$BIN_DIR"
install -m 755 zig-out/bin/waybar-gmail "$BIN_DIR/waybar-gmail"
install -m 755 zig-out/bin/waybar-gmail-popup "$BIN_DIR/waybar-gmail-popup"

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        warn "$BIN_DIR is not on your PATH."
        warn "the waybar module runs waybar-gmail, and click.zig spawns"
        warn "waybar-gmail-popup, by bare name via PATH lookup -- add $BIN_DIR to"
        warn "PATH in your shell profile, or the module and popup won't be found."
        ;;
esac

log "Setting up $APP_CONFIG_DIR..."
mkdir -p "$APP_CONFIG_DIR"
chmod 700 "$APP_CONFIG_DIR"

if [[ ! -f "$APP_CONFIG_DIR/client_secret.json" ]]; then
    echo
    echo "No Google OAuth credentials found at:"
    echo "    $APP_CONFIG_DIR/client_secret.json"
    echo "See README.md for how to create one (a one-time, ~5 minute Google Cloud"
    echo "Console step), then run:"
    echo "    waybar-gmail auth"
    echo
fi

log "Updating $STYLE_FILE..."
mkdir -p "$WAYBAR_CONFIG_DIR"
if [[ -f "$STYLE_FILE" ]] && grep -q '#custom-gmail' "$STYLE_FILE"; then
    log "  style.css already has a #custom-gmail block -- leaving it alone."
else
    if [[ -f "$STYLE_FILE" ]]; then
        BACKUP="$STYLE_FILE.bak.$(date +%Y%m%d%H%M%S)"
        cp "$STYLE_FILE" "$BACKUP"
        log "  backed up existing style.css -> $(basename "$BACKUP")"
    fi
    {
        echo ""
        echo "/* --- waybar-gmail-checker: appended by install.sh on $(date -Iseconds) --- */"
        cat "$SCRIPT_DIR/waybar/style-snippet.css"
    } >> "$STYLE_FILE"
    log "  appended the #custom-gmail style block."
fi

cat <<EOF

============================================================
Almost done -- one manual step left.

Add "custom/gmail" to modules-right (or wherever you'd like it) in:
    $WAYBAR_CONFIG_DIR/config.jsonc

Then merge this block into the top level of that same file:

$(cat "$SCRIPT_DIR/waybar/config-snippet.jsonc")

This isn't automated because config.jsonc is hand-maintained (comments,
specific module ordering) and a script guessing where to splice JSON
into that safely, for every possible existing config, is more likely to
mangle it than help. See the full snippet with comments at:
    $SCRIPT_DIR/waybar/config-snippet.jsonc

Once that's saved, reload waybar:
    pkill -x -SIGUSR2 waybar
============================================================
EOF
