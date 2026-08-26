#!/bin/bash
# Drives the plugin headlessly against tests/fake-claude, which replays the
# event shapes `claude --output-format stream-json` really emits.
set -euo pipefail
export ASKIA_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ASKIA_ARGV_LOG="$(mktemp)"
# Keep the session store out of the real ~/.local/state/nvim.
export XDG_STATE_HOME="$(mktemp -d)"
trap 'rm -rf "$ASKIA_ARGV_LOG" "$XDG_STATE_HOME"' EXIT
cd "$ASKIA_ROOT/tests"
exec nvim --headless -u NONE -l "$ASKIA_ROOT/tests/spec.lua"
