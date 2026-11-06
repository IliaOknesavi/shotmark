#!/bin/bash
# One-shot install: clone (if needed), build, sign, install to ~/Applications, launch,
# and connect the MCP server to Claude Code. Safe to re-run: it updates and rebuilds.
#
#   curl -fsSL https://raw.githubusercontent.com/IliaOknesavi/shotmark/main/scripts/install.sh | bash
set -euo pipefail
REPO="https://github.com/IliaOknesavi/shotmark.git"
DIR="${SHOTMARK_DIR:-$HOME/shotmark}"

# Run from a pipe or from outside a checkout: get the source first.
SELF="${BASH_SOURCE[0]:-}"
if [ -z "$SELF" ] || [ ! -f "$(dirname "$SELF")/../Package.swift" ]; then
  if [ -d "$DIR/.git" ]; then git -C "$DIR" pull --ff-only; else git clone "$REPO" "$DIR"; fi
  exec bash "$DIR/scripts/install.sh"
fi
cd "$(dirname "$SELF")/.."

[ "$(uname)" = Darwin ] || { echo "Shotmark is a macOS app"; exit 1; }
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 15 ] || { echo "Shotmark needs macOS 15 or newer"; exit 1; }
command -v swift >/dev/null || { echo "Swift not found: run 'xcode-select --install' and re-run this script"; exit 1; }

scripts/make-cert.sh
scripts/build.sh
APP="$HOME/Applications/Shotmark.app"
open "$APP"

TOKEN_FILE="$HOME/Library/Application Support/Shotmark/token"
for _ in $(seq 1 40); do [ -s "$TOKEN_FILE" ] && break; sleep 0.25; done
[ -s "$TOKEN_FILE" ] || { echo "Shotmark did not start: open $APP manually"; exit 1; }
TOKEN="$(cat "$TOKEN_FILE")"
URL="http://127.0.0.1:47830/mcp"

if command -v claude >/dev/null; then
  claude mcp remove --scope user shotmark >/dev/null 2>&1 || true
  claude mcp add --scope user --transport http shotmark "$URL" --header "Authorization: Bearer $TOKEN" >/dev/null
  echo "Connected to Claude Code (user scope: every project and chat)."
else
  echo "Claude Code CLI not found. To connect it later:"
  echo "  claude mcp add --scope user --transport http shotmark $URL --header \"Authorization: Bearer \$(cat '$TOKEN_FILE')\""
fi

cat <<EOF

Shotmark is installed: $APP
It starts at login and lives in the menu bar.

One-time steps for you:
  1. System Settings → Privacy & Security → Screen & System Audio Recording → enable Shotmark,
     then quit Shotmark from its menu and open it again.
  2. When Shotmark asks, let it take over ⌘⇧3 / ⌘⇧4 / ⌘⇧5 from the built-in screenshots.
EOF
