#!/usr/bin/env bash
set -euo pipefail

# Build Maquake, sign it, and optionally install to /Applications.
# Usage: ./scripts/build-install.sh [--install]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_BUNDLE="$PROJECT_ROOT/build/Macuake.app"
ENTITLEMENTS="$PROJECT_ROOT/MaQuake/Resources/MaQuake.entitlements"
BINARY="$APP_BUNDLE/Contents/MacOS/Macuake"
SIGNING_IDENTITY="Developer ID Application: Denti.AI Technology Inc (45N4N4R4C3)"

cd "$PROJECT_ROOT"

echo "==> Building universal release (arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

echo "==> Copying binary..."
cp .build/apple/Products/Release/Macuake "$BINARY"

echo "==> Copying Info.plist..."
cp "$PROJECT_ROOT/MaQuake/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Copying resource bundles..."
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
mkdir -p "$RESOURCES_DIR"
for bundle in .build/apple/Products/Release/*.bundle; do
    [ -d "$bundle" ] || continue
    name="$(basename "$bundle")"
    rm -rf "$RESOURCES_DIR/$name"
    cp -R "$bundle" "$RESOURCES_DIR/$name"
    echo "    $name"
done

echo "==> Embedding Sparkle.framework..."
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
SPARKLE_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$SPARKLE_SRC" ]; then
    rm -rf "$FRAMEWORKS_DIR/Sparkle.framework"
    cp -R "$SPARKLE_SRC" "$FRAMEWORKS_DIR/Sparkle.framework"
else
    echo "WARNING: Sparkle.framework not found at $SPARKLE_SRC"
fi

echo "==> Fixing rpath for embedded frameworks..."
install_name_tool -add_rpath "@executable_path/../Frameworks" "$BINARY" 2>/dev/null || true

echo "==> Signing with: $SIGNING_IDENTITY"
codesign --force --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --deep "$APP_BUNDLE"

codesign --verify --deep --strict "$APP_BUNDLE"
echo "==> Signed and verified: $APP_BUNDLE"

# Always install: kill running instance, force-replace, relaunch
echo "==> Installing to /Applications..."
killall Macuake 2>/dev/null || true
sleep 0.3
rm -rf /Applications/Macuake.app
cp -R "$APP_BUNDLE" /Applications/Macuake.app
echo "==> Installed: /Applications/Macuake.app"

echo "Done."
