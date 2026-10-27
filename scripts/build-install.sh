#!/usr/bin/env bash
set -euo pipefail

# Build a local Maquake.app bundle. Use --install to additionally install it as
# /Applications/Macuake_dev.app without replacing the released application.
#
# Usage:
#   ./scripts/build-install.sh [--install]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="Macuake"
APP_BUNDLE="$PROJECT_ROOT/build/${APP_NAME}.app"
ENTITLEMENTS="$PROJECT_ROOT/MaQuake/Resources/MaQuake.entitlements"
SIGNING_IDENTITY="Developer ID Application: Denti.AI Technology Inc (45N4N4R4C3)"
INSTALL_NAME="Macuake_dev"
INSTALL_BUNDLE="/Applications/${INSTALL_NAME}.app"
INSTALL=false

usage() {
    cat <<'EOF'
Usage: ./scripts/build-install.sh [--install]

Builds build/Macuake.app for the current machine by default.

Options:
  --install    Also install the build as /Applications/Macuake_dev.app.
  --help       Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install) INSTALL=true ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

cd "$PROJECT_ROOT"

echo "==> Ensuring native GhosttyKit..."
"$SCRIPT_DIR/build-ghostty.sh"

# swift-sdk 0.11 is not yet Swift 6.3 concurrency-clean. The project declares
# Swift 5.10 and this keeps local builds compatible with that language mode.
SWIFT_BUILD_ARGS=(-Xswiftc -swift-version -Xswiftc 5 -c release)

build_arch() {
    local arch="$1"
    echo "==> Building ${arch} release binary..."
    swift build "${SWIFT_BUILD_ARGS[@]}" --arch "$arch"
}

bin_dir_for_arch() {
    local arch="$1"
    swift build "${SWIFT_BUILD_ARGS[@]}" --arch "$arch" --show-bin-path
}

NATIVE_ARCH="$(uname -m)"
build_arch "$NATIVE_ARCH"
RESOURCE_BUILD_DIR="$(bin_dir_for_arch "$NATIVE_ARCH")"

echo "==> Creating application bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cp "$RESOURCE_BUILD_DIR/$APP_NAME" "$BINARY"

cp "$PROJECT_ROOT/MaQuake/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_ROOT/MaQuake/Resources/maquake.icns" "$APP_BUNDLE/Contents/Resources/"

echo "==> Copying resource bundles..."
shopt -s nullglob
for bundle in "$RESOURCE_BUILD_DIR"/*.bundle; do
    [ -f "$bundle/Info.plist" ] || [ -f "$bundle/Contents/Info.plist" ] || continue
    ditto "$bundle" "$APP_BUNDLE/Contents/Resources/$(basename "$bundle")"
    echo "    $(basename "$bundle")"
done
shopt -u nullglob

SPARKLE_SRC="$RESOURCE_BUILD_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE_SRC" ]; then
    SPARKLE_SRC="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi
if [ ! -d "$SPARKLE_SRC" ]; then
    echo "Error: Sparkle.framework was not produced by the build." >&2
    exit 1
fi
echo "==> Embedding Sparkle.framework..."
ditto "$SPARKLE_SRC" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

install_name_tool -add_rpath "@executable_path/../Frameworks" "$BINARY"

if security find-identity -v -p codesigning | grep -q "$SIGNING_IDENTITY"; then
    SIGN_ID="$SIGNING_IDENTITY"
    USE_RUNTIME_SIGNATURE=true
    echo "==> Signing with: $SIGN_ID"
else
    SIGN_ID="-"
    USE_RUNTIME_SIGNATURE=false
    echo "==> Signing ad-hoc for local use"
fi

sign() {
    if [ "$USE_RUNTIME_SIGNATURE" = true ]; then
        codesign --force --sign "$SIGN_ID" --options runtime "$@"
    else
        codesign --force --sign "$SIGN_ID" "$@"
    fi
}

for bundle in "$APP_BUNDLE"/Contents/Resources/*.bundle; do
    [ -d "$bundle" ] || continue
    codesign --force --sign "$SIGN_ID" "$bundle"
done
sign --deep "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
sign --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"
echo "==> Signed and verified: $APP_BUNDLE"

if [ "$INSTALL" = true ]; then
    echo "==> Installing to $INSTALL_BUNDLE..."
    pkill -x "$INSTALL_NAME" 2>/dev/null || true
    rm -rf "$INSTALL_BUNDLE"
    ditto "$APP_BUNDLE" "$INSTALL_BUNDLE"
    mv "$INSTALL_BUNDLE/Contents/MacOS/$APP_NAME" \
        "$INSTALL_BUNDLE/Contents/MacOS/$INSTALL_NAME"
    /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $INSTALL_NAME" \
        "$INSTALL_BUNDLE/Contents/Info.plist"
    sign --entitlements "$ENTITLEMENTS" "$INSTALL_BUNDLE"
    codesign --verify --deep --strict "$INSTALL_BUNDLE"
    echo "==> Installed: $INSTALL_BUNDLE"
fi

echo "Done."
