#!/bin/sh
# Claude Code hook for Notch: forwards the hook event (JSON on stdin) to the
# Notch app over a local socket. Silent, and harmless, when Notch is not running.
APP="$(cd "$(dirname "$0")/.." && pwd)/MacOS/Notch"
[ -x "$APP" ] || exit 0
exec "$APP" --hook
