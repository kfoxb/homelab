#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin"
TARGET="${INSTALL_DIR}/ccw"

mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/ccw" "$TARGET"
chmod +x "$TARGET"

echo "Installed ccw to $TARGET"

# Remind the user to add ~/.local/bin to PATH if it's not already there.
if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  echo "Note: $INSTALL_DIR is not in your PATH."
  echo "      Add the following to your shell profile:"
  echo "        export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
