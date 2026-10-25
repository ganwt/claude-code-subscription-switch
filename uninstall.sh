#!/usr/bin/env bash
# Remove claude-switch: settings.json entries, symlink and program copy.
# State, logs and the API key file in ~/.config/claude-switch are left for you to delete.
set -euo pipefail
DEST_DIR="$HOME/.local/share/claude-switch"
BIN="$HOME/.local/bin/claude-switch"

if [ -x "$DEST_DIR/claude-switch" ]; then
  "$DEST_DIR/claude-switch" uninstall
fi
rm -f "$BIN"
rm -rf "$DEST_DIR"
echo "removed $BIN and $DEST_DIR"
echo "to remove state/logs/key:  rm -rf ~/.config/claude-switch"
