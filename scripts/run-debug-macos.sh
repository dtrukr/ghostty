#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT_DIR}/macos/build/Debug/Ghostty.app"
BIN="${APP}/Contents/MacOS/ghostty"

if ! command -v zig >/dev/null 2>&1; then
  echo "zig not found in PATH"
  exit 1
fi

# Ensure we don't accidentally override the user's default Ghostty config
# through a lingering launchd env var from prior debug sessions.
launchctl unsetenv GHOSTTY_CONFIG_PATH >/dev/null 2>&1 || true

# Close any running Debug app instance.
pkill -f "${BIN}" >/dev/null 2>&1 || true

echo "Building debug macOS app..."
zig build -Doptimize=Debug -Demit-macos-app=true -Dxcframework-target=native

if [[ ! -x "${BIN}" ]]; then
  echo "Debug app not found at: ${BIN}"
  exit 1
fi

# Launch using the default Ghostty config (no GHOSTTY_CONFIG_PATH).
if ! open -n "${APP}"; then
  echo "LaunchServices open failed, falling back to direct binary launch..."
  "${BIN}" >/tmp/ghostty-debug.log 2>&1 &
fi
