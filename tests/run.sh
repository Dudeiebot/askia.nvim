#!/bin/bash
# Drives the plugin headlessly against tests/fake-claude, which replays the
# event shapes `claude --output-format stream-json` really emits.
set -euo pipefail
export ASKING_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export ASKING_ARGV_LOG="$(mktemp)"
trap 'rm -f "$ASKING_ARGV_LOG"' EXIT
cd "$ASKING_ROOT/tests"
exec nvim --headless -u NONE -l "$ASKING_ROOT/tests/spec.lua"
