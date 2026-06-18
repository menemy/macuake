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

# Xcode 26 libtool (cctools_ld-1267) silently drops .o files that aren't
# 8-byte aligned; zig 0.15.x emits misaligned objects. Rebuild each
# platform library from the intermediate .a files using ar (no alignment check).
for lib_dir in "$XCFRAMEWORK_DIR"/*/; do
    fat_lib="$lib_dir/libghostty-fat.a"
    [ -f "$fat_lib" ] || continue

    fat_sym_count=$(nm "$fat_lib" 2>/dev/null | grep -c " T _ghostty_app_new" || true)
    if [ "$fat_sym_count" -gt 0 ]; then
        continue
    fi

    echo "Rebuilding $(basename "$lib_dir")/libghostty-fat.a (libtool dropped misaligned objects)..."
    MERGE_DIR=$(mktemp -d)

    # Extract all intermediate .a files from zig-cache, in order: dependencies first, ghostty last
    for archive in "$GHOSTTY_DIR"/.zig-cache/o/*/lib*.a; do
        [ -f "$archive" ] || continue
        base=$(basename "$archive")
        # Skip the fat lib itself and shared lib stubs
        [ "$base" = "libghostty-fat.a" ] && continue
        echo "$base" | grep -q "libghostty-vt" && continue
        # Extract to a subdir to avoid name collisions, then move with unique prefix
        SUB=$(mktemp -d)
        (cd "$SUB" && ar x "$archive" && chmod 644 *.o 2>/dev/null || true)
        for obj in "$SUB"/*.o; do
            [ -f "$obj" ] || continue
            name=$(basename "$obj")
            if [ ! -f "$MERGE_DIR/$name" ]; then
                mv "$obj" "$MERGE_DIR/$name"
            fi
        done
        rm -rf "$SUB"
    done

    obj_count=$(ls "$MERGE_DIR"/*.o 2>/dev/null | wc -l | tr -d ' ')
    ar rcs "$fat_lib" "$MERGE_DIR"/*.o
    ranlib "$fat_lib"
    rm -rf "$MERGE_DIR"
    ghostty_syms=$(nm "$fat_lib" 2>/dev/null | grep -c ' T _ghostty' || echo 0)
    echo "  Done: $obj_count objects, $ghostty_syms ghostty symbols"
done

echo "$CURRENT_SHA" > "$CACHE_FILE"
echo "Build complete: $XCFRAMEWORK_DIR"
