#!/usr/bin/env bash
set -euo pipefail

# Build GhosttyKit.xcframework from the vendored ghostty submodule.
# Uses SHA-based caching to skip rebuilds when the submodule hasn't changed.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GHOSTTY_DIR="$PROJECT_ROOT/vendor/ghostty"
XCFRAMEWORK_DIR="$GHOSTTY_DIR/macos/GhosttyKit.xcframework"
CACHE_FILE="$PROJECT_ROOT/.ghostty-build-sha"

if [ ! -d "$GHOSTTY_DIR/.git" ] && [ ! -f "$GHOSTTY_DIR/.git" ]; then
    echo "Error: vendor/ghostty submodule not found."
    echo "Run: git submodule update --init vendor/ghostty"
    exit 1
fi

if ! command -v zig &>/dev/null; then
    echo "Error: zig not found. Install with: brew install zig"
    exit 1
fi

# Get current submodule SHA
CURRENT_SHA=$(cd "$GHOSTTY_DIR" && git rev-parse HEAD)

# Check cache
if [ -f "$CACHE_FILE" ] && [ -d "$XCFRAMEWORK_DIR" ]; then
    CACHED_SHA=$(cat "$CACHE_FILE")
    if [ "$CURRENT_SHA" = "$CACHED_SHA" ]; then
        echo "GhosttyKit.xcframework is up to date (SHA: ${CURRENT_SHA:0:12})"
        exit 0
    fi
fi

TARGET_FLAG="-Dxcframework-target=native"
if [ "${1:-}" = "--universal" ]; then
    TARGET_FLAG=""
    echo "Building GhosttyKit.xcframework [universal] (SHA: ${CURRENT_SHA:0:12})..."
else
    echo "Building GhosttyKit.xcframework [native] (SHA: ${CURRENT_SHA:0:12})..."
fi

cd "$GHOSTTY_DIR"

# Remove stale xcframework if it exists (xcodebuild -create-xcframework fails if output exists)
rm -rf "$XCFRAMEWORK_DIR"

zig build -Demit-xcframework=true -Demit-macos-app=false -Doptimize=ReleaseFast $TARGET_FLAG

if [ ! -d "$XCFRAMEWORK_DIR" ]; then
    echo "Error: xcframework not found at $XCFRAMEWORK_DIR after build."
    exit 1
fi

echo "$CURRENT_SHA" > "$CACHE_FILE"
echo "Build complete: $XCFRAMEWORK_DIR"
