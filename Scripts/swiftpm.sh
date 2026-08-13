#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SWIFTPM_STATE_DIR="$ROOT_DIR/.build/swiftpm-state"
CLANG_CACHE_DIR="$ROOT_DIR/.build/cache/clang-module-cache"
MODULE_CACHE_DIR="$ROOT_DIR/.build/cache/swiftpm-module-cache"

if (($# == 0)); then
  printf 'Usage: %s <build|test|run|package> [arguments...]\n' "$(basename "$0")" >&2
  exit 64
fi

SWIFT_SUBCOMMAND="$1"
shift

mkdir -p \
  "$SWIFTPM_STATE_DIR/cache" \
  "$SWIFTPM_STATE_DIR/config" \
  "$SWIFTPM_STATE_DIR/security" \
  "$CLANG_CACHE_DIR" \
  "$MODULE_CACHE_DIR"

export CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"

# Codex already confines the command to the workspace. Disabling SwiftPM's
# nested sandbox avoids sandbox-exec failures while preserving the outer one.
exec swift "$SWIFT_SUBCOMMAND" \
  --disable-sandbox \
  --cache-path "$SWIFTPM_STATE_DIR/cache" \
  --config-path "$SWIFTPM_STATE_DIR/config" \
  --security-path "$SWIFTPM_STATE_DIR/security" \
  "$@"
