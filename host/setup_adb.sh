#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-27183}"

if ! command -v adb >/dev/null 2>&1; then
  echo "adb not found in PATH"
  exit 1
fi

adb start-server >/dev/null
adb devices
adb reverse "tcp:${PORT}" "tcp:${PORT}"

echo "ADB reverse configured: device localhost:${PORT} -> host localhost:${PORT}"

