#!/usr/bin/env bash
# Runs `zig build test` against a throwaway Secret Service, for containers/CI
# where there's no desktop keyring. The tests in src/secrets.zig call the real
# `secret-tool`, which needs org.freedesktop.secrets on a session bus.
#
# Hermetic on purpose: a private session bus (dbus-run-session) and a
# temporary HOME and XDG_RUNTIME_DIR, so running this on a dev machine can
# never reach, or write into, your real keyring. Needs dbus-run-session,
# gnome-keyring-daemon and secret-tool on PATH. Run as a non-root user:
# gnome-keyring-daemon aborts at startup as root inside a container.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

export HOME="$scratch/home"
export XDG_RUNTIME_DIR="$scratch/run"
mkdir -p "$HOME/.local/share/keyrings" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

# A pre-seeded, unencrypted "login" keyring. gnome-keyring otherwise wants to
# create one through a GUI password prompt (gcr-prompter), which can't work
# without a display; an unencrypted one needs no unlock password and no prompt.
printf login > "$HOME/.local/share/keyrings/default"
cat > "$HOME/.local/share/keyrings/login.keyring" <<'EOF'
[keyring]
display-name=login
ctime=0
mtime=0
lock-on-idle=false
lock-after=false
EOF

# Extra arguments (e.g. --summary all) are passed through to `zig build test`.
cd "$repo"
dbus-run-session -- bash -euc '
    scratch="$1"; shift
    gnome-keyring-daemon --start --components=secrets >/dev/null
    zig build test --cache-dir "$scratch/zig-local" --global-cache-dir "$scratch/zig-global" "$@"
' _ "$scratch" "$@"
