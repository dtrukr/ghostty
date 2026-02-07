#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT_DIR}/macos/build/Debug/Ghostty.app"
BIN="${APP}/Contents/MacOS/ghostty"

# Ensure we don't accidentally override the user's default Ghostty config
# through a lingering launchd env var from prior debug sessions.
launchctl unsetenv GHOSTTY_CONFIG_PATH >/dev/null 2>&1 || true

if [[ ! -x "${BIN}" ]]; then
  echo "Debug app not found at: ${BIN}"
  echo "Build it once with: zig build run -Doptimize=Debug"
  exit 1
fi

# Close any running Debug app instance.
pkill -f "${BIN}" >/dev/null 2>&1 || true

# Make LaunchServices happy if the bundle got modified (common during dev).
/usr/bin/codesign --force --deep --sign - --timestamp=none "${APP}" >/dev/null 2>&1 || true

# Launch using the default Ghostty config (no GHOSTTY_CONFIG_PATH).
open -n "${APP}"

