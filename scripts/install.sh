#!/bin/bash
# ZhiYin - Installation script
# Usage: ./scripts/install.sh [--no-launchd]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="ZhiYin"
BUNDLE_ID="com.zhiyin.app"
VENV_DIR="$PROJECT_DIR/.venv"

cd "$PROJECT_DIR"
source "$SCRIPT_DIR/env-xcode.sh" 2>/dev/null || true

echo "=== 知音 ZhiYin Installer ==="
echo ""

# 1. Check Python
echo "[1/5] Checking Python environment..."
if command -v python3 &>/dev/null; then
    PY_VERSION=$(python3 --version 2>&1)
    echo "  Found: $PY_VERSION"
else
    echo "  ERROR: python3 not found. Please install Python 3.10+."
    exit 1
fi

# 2. Setup venv and install dependencies
echo "[2/5] Setting up Python dependencies..."
if [[ ! -d "$VENV_DIR" ]]; then
    echo "  Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
fi

source "$VENV_DIR/bin/activate"
echo "  Installing packages..."
pip install -q fastapi uvicorn soundfile numpy mlx-audio==0.2.10 huggingface-hub opencc-python-reimplemented mlx-whisper==0.4.3

# 3. Download model
echo "[3/5] Downloading STT model (this may take a while)..."
python3 -c "
from huggingface_hub import snapshot_download
path = snapshot_download('mlx-community/Fun-ASR-MLT-Nano-2512-8bit')
print(f'  Model downloaded to: {path}')
"

# 4. Build Swift
echo "[4/5] Building Swift application (release)..."
swift build -c release 2>&1 | tail -5
BINARY_PATH=".build/release/zhiyin"

if [[ ! -f "$BINARY_PATH" ]]; then
    echo "  ERROR: Build failed."
    exit 1
fi
echo "  Build successful."

# 5. Create .app bundle
echo "[5/5] Creating application bundle..."
APP_DIR="$PROJECT_DIR/.build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BINARY_PATH" "$MACOS_DIR/zhiyin"
cp "ZhiYin/Sources/Info.plist" "$CONTENTS_DIR/Info.plist"

if [[ -d "models" ]] && [[ "$(ls -A models 2>/dev/null)" ]]; then
    cp -r models "$RESOURCES_DIR/"
fi

echo "  App bundle: $APP_DIR"

# Optional: launchd auto-start
if [[ "$1" != "--no-launchd" ]]; then
    echo ""
    read -p "Create launchd plist for auto-start on login? [y/N] " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        PLIST_DIR="$HOME/Library/LaunchAgents"
        PLIST_PATH="$PLIST_DIR/$BUNDLE_ID.plist"
        mkdir -p "$PLIST_DIR"

        cat > "$PLIST_PATH" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>open</string>
        <string>$APP_DIR</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
PLISTEOF
        echo "  LaunchAgent installed: $PLIST_PATH"
        echo "  ZhiYin will start automatically on next login."
    fi
fi

echo ""
echo "=== Installation complete! ==="
echo ""
echo "To run now:  ./scripts/run-dev.sh"
echo "Or:          open $APP_DIR"
echo ""
echo "Required permissions (grant on first run):"
echo "  - Microphone access"
echo "  - Accessibility (System Settings > Privacy > Accessibility)"
