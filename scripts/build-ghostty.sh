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

ZIG_015="$(brew --prefix zig@0.15 2>/dev/null)/bin/zig"
if [ -x "$ZIG_015" ]; then
    export PATH="$(dirname "$ZIG_015"):$PATH"
elif ! command -v zig &>/dev/null; then
    echo "Error: zig 0.15.x not found. Install with: brew install zig@0.15"
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

# Helper: rebuild a single-arch .a from zig-cache archives matching $1 (arch filter)
rebuild_from_cache() {
    local target_arch="$1"
    local out_file="$2"
    local merge_dir
    merge_dir=$(mktemp -d)

    for archive in "$GHOSTTY_DIR"/.zig-cache/o/*/lib*.a; do
        [ -f "$archive" ] || continue
        base=$(basename "$archive")
        [ "$base" = "libghostty-fat.a" ] && continue
        echo "$base" | grep -q "libghostty-vt" && continue
        # Skip fat (multi-arch) files — ar can't extract them
        arch_count=$(lipo -info "$archive" 2>/dev/null | grep -oE 'arm64|x86_64' | wc -l | tr -d ' ')
        [ "$arch_count" -gt 1 ] && continue
        # Filter by architecture if specified
        if [ -n "$target_arch" ]; then
            file_arch=$(lipo -info "$archive" 2>/dev/null | grep -oE 'arm64|x86_64' | head -1 || true)
            [ "$file_arch" = "$target_arch" ] || continue
        fi
        SUB=$(mktemp -d)
        (cd "$SUB" && ar x "$archive" && chmod 644 *.o 2>/dev/null || true)
        for obj in "$SUB"/*.o; do
            [ -f "$obj" ] || continue
            name=$(basename "$obj")
            [ ! -f "$merge_dir/$name" ] && mv "$obj" "$merge_dir/$name"
        done
        rm -rf "$SUB"
    done

    local obj_count
    obj_count=$(ls "$merge_dir"/*.o 2>/dev/null | wc -l | tr -d ' ')
    ar rcs "$out_file" "$merge_dir"/*.o
    ranlib "$out_file"
    rm -rf "$merge_dir"
    echo "    $target_arch: $obj_count objects"
}

for lib_dir in "$XCFRAMEWORK_DIR"/*/; do
    # Handle single-arch libghostty-fat.a
    fat_lib="$lib_dir/libghostty-fat.a"
    if [ -f "$fat_lib" ]; then
        sym_count=$(nm "$fat_lib" 2>/dev/null | grep -c " T _ghostty_app_new" || true)
        if [ "$sym_count" -eq 0 ]; then
            echo "Rebuilding $(basename "$lib_dir")/libghostty-fat.a (libtool dropped misaligned objects)..."
            rebuild_from_cache "" "$fat_lib"
            ghostty_syms=$(nm "$fat_lib" 2>/dev/null | grep -c ' T _ghostty' || echo 0)
            echo "  Done: $ghostty_syms ghostty symbols"
        fi
    fi

    # Handle universal lipo'd libghostty.a
    lipo_lib="$lib_dir/libghostty.a"
    if [ -f "$lipo_lib" ]; then
        sym_count=$(nm "$lipo_lib" 2>/dev/null | grep -c " T _ghostty_app_new" || true)
        if [ "$sym_count" -eq 0 ]; then
            echo "Rebuilding $(basename "$lib_dir")/libghostty.a (libtool dropped misaligned objects)..."
            WORK_DIR=$(mktemp -d)
            archs=$(lipo -info "$lipo_lib" 2>/dev/null | grep -oE 'arm64|x86_64' | sort -u || true)
            for arch in $archs; do
                rebuild_from_cache "$arch" "$WORK_DIR/lib-$arch.a"
            done
            lipo_args=""
            for arch in $archs; do
                lipo_args="$lipo_args $WORK_DIR/lib-$arch.a"
            done
            lipo -create $lipo_args -output "$lipo_lib"
            rm -rf "$WORK_DIR"
            ghostty_syms=$(nm "$lipo_lib" 2>/dev/null | grep -c ' T _ghostty' || echo 0)
            echo "  Done: $ghostty_syms ghostty symbols"
        fi
    fi
done

echo "$CURRENT_SHA" > "$CACHE_FILE"
echo "Build complete: $XCFRAMEWORK_DIR"
