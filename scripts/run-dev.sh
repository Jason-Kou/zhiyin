#!/bin/bash
# Run ZhiYin in development mode with console output in terminal
# Usage: ./scripts/run-dev.sh [--rebuild]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/env-xcode.sh" 2>/dev/null || true
cd "$PROJECT_DIR"

APP_BUNDLE=".build/ZhiYin-Dev.app"
BINARY=".build/debug/zhiyin"

# Kill ALL existing zhiyin processes (app + python server)
pkill -f zhiyin 2>/dev/null || true
# Kill any process occupying the STT server port
lsof -ti:17760 | xargs kill 2>/dev/null || true
sleep 1

# Rebuild if requested or binary doesn't exist
if [[ "${1:-}" == "--rebuild" ]] || [[ ! -f "$BINARY" ]]; then
    echo "Building ZhiYin (debug)..."
    swift build -c debug
fi

# Create .app bundle with COPIED binary
echo "Creating dev .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# COPY the binary so Bundle.main resolves to .app/Contents/
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/zhiyin"

# Add rpath for ../Frameworks so Sparkle.framework is found
install_name_tool -add_rpath @loader_path/../Frameworks "$APP_BUNDLE/Contents/MacOS/zhiyin" 2>/dev/null || true

# Re-sign with stable developer identity so Accessibility permission persists across rebuilds.
# Falls back to ad-hoc signing if no developer certificate is available.
DEV_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [ -n "$DEV_IDENTITY" ]; then
    codesign --force --sign "$DEV_IDENTITY" --identifier com.zhiyin.app "$APP_BUNDLE/Contents/MacOS/zhiyin"
    echo "  ✓ Signed with: $DEV_IDENTITY"
else
    codesign --force --sign - --identifier com.zhiyin.app "$APP_BUNDLE/Contents/MacOS/zhiyin"
    echo "  ⚠ Ad-hoc signed (Accessibility permission may reset on rebuild)"
fi

# Copy Info.plist
cp ZhiYin/Sources/Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Copy Sparkle.framework
SPARKLE_FW=".build/arm64-apple-macosx/debug/Sparkle.framework"
if [ ! -d "$SPARKLE_FW" ]; then
    SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi
if [ -d "$SPARKLE_FW" ]; then
    cp -R "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/"
    echo "  ✓ Sparkle.framework copied"
fi

# Bundle CLI binary (build if needed)
CLI_BINARY=".build/debug/zhiyin-stt"
if [ ! -f "$CLI_BINARY" ]; then
    swift build --product zhiyin-stt
fi
mkdir -p "$APP_BUNDLE/Contents/Resources/bin"
cp "$CLI_BINARY" "$APP_BUNDLE/Contents/Resources/bin/zhiyin-stt"

# Symlink python server and models
ln -sf "$(pwd)/python" "$APP_BUNDLE/Contents/Resources/python"
if [ -d "models" ]; then
    ln -sf "$(pwd)/models" "$APP_BUNDLE/Contents/Resources/models"
fi

# NOTE: We no longer reset Accessibility permission here.
# With stable code signing, the permission persists across rebuilds.

echo "========================================="
echo "  ZhiYin Dev — Console Mode"
echo "  Ctrl+C to quit"
echo "========================================="

# Clean up on exit: kill python server too
cleanup() {
    echo ""
    echo "Shutting down..."
    pkill -f "stt_server.py" 2>/dev/null || true
    exit 0
}
trap cleanup INT TERM

# Run directly in foreground so all output goes to terminal
exec "$APP_BUNDLE/Contents/MacOS/zhiyin"
