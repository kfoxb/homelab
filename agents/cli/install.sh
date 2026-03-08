#!/usr/bin/env bash
# install.sh — Standalone one-liner installer for ccw
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/kfoxb/homelab/main/agents/cli/install.sh | bash
#
# Or to install from a specific ref:
#   curl -sL https://raw.githubusercontent.com/kfoxb/homelab/main/agents/cli/install.sh | bash -s -- --ref main
#
# What this does:
#   1. Downloads ccw to ~/.local/bin/ccw
#   2. Makes it executable
#   3. Prints a reminder to set CCW_HOMELAB_DIR if you want ccw start to work
set -euo pipefail

CCW_REF="main"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) CCW_REF="$2"; shift 2 ;;
    *) shift ;;
  esac
done

INSTALL_DIR="${CCW_INSTALL_DIR:-${HOME}/.local/bin}"
CCW_URL="https://raw.githubusercontent.com/kfoxb/homelab/${CCW_REF}/agents/cli/ccw"

mkdir -p "$INSTALL_DIR"

echo "Downloading ccw from ${CCW_URL} ..."
curl -fsSL "$CCW_URL" -o "${INSTALL_DIR}/ccw"
chmod +x "${INSTALL_DIR}/ccw"

echo "Installed ccw to ${INSTALL_DIR}/ccw"

# Warn if install dir is not in PATH
if ! echo ":${PATH}:" | grep -q ":${INSTALL_DIR}:"; then
  echo ""
  echo "WARNING: ${INSTALL_DIR} is not in your PATH."
  echo "Add the following to your ~/.bashrc or ~/.zshrc:"
  echo ""
  echo "  export PATH=\"\${HOME}/.local/bin:\${PATH}\""
fi

echo ""
echo "To use 'ccw start', set CCW_HOMELAB_DIR to your cloned homelab repo:"
echo ""
echo "  export CCW_HOMELAB_DIR=~/homelab"
echo ""
echo "Read-only commands (list, status, ssh, logs, stop, dismiss) work without it."
echo ""
echo "Run 'ccw --help' to get started."
