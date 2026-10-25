#!/usr/bin/env bash
# Install claude-switch into the current WSL user account.
#  - copies bin/claude-switch to ~/.local/share/claude-switch/ (so it does not depend on /mnt/d)
#  - symlinks ~/.local/bin/claude-switch
#  - registers statusLine + hooks in ~/.claude/settings.json (backup taken first)
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)/bin/claude-switch"
DEST_DIR="$HOME/.local/share/claude-switch"
BIN_DIR="$HOME/.local/bin"

command -v python3 >/dev/null || { echo "python3 is required"; exit 1; }
mkdir -p "$DEST_DIR" "$BIN_DIR"
install -m 755 "$SRC" "$DEST_DIR/claude-switch"
ln -sfn "$DEST_DIR/claude-switch" "$BIN_DIR/claude-switch"
"$DEST_DIR/claude-switch" install
echo
echo "Then:"
echo "  claude-switch set-key        # store the API key (hidden input), or: printf %s \"\$KEY\" | claude-switch set-key"
echo "  claude-switch status"
