#!/bin/bash
set -euo pipefail

# ZhiYin Release DMG Packaging Script
# Usage: ./scripts/make-dmg.sh
#
# Produces a signed .dmg with bundled Python runtime and dependencies.
# STT models are NOT bundled — they download automatically on first launch.
# Not notarized — users bypass Gatekeeper with: xattr -cr ZhiYin.app
#
# ── PACKAGING NOTES (lessons learned) ────────────────────────────────────────
#
# Bundle contents:
#   Swift binary + Python 3.12 runtime (44MB) + slim site-packages (~600MB)
#   → compressed DMG ~100MB
#
# Architecture:
#   Swift app detects bundled Python at Contents/Resources/python-runtime/bin/python3
#   Sets PYTHONPATH → Contents/Resources/python-packages (no venv needed)
#   Models download to ~/.cache/huggingface/hub/ on first launch
#
# Critical pitfalls:
#   1. Do NOT remove unittest from Python stdlib — torch imports it at init
#   2. mlx-audio==0.2.10 PyPI wheel is MISSING mlx_audio/stt/models/funasr/
#      → must copy from working dev venv (patched below)
#   3. Do NOT strip torch aggressively — circular deps break imports
#      Only safe: torch/include/ (C++ headers), torch/share/ (CMake)
#   4. silero-vad requires torchaudio — don't forget it
#   5. Venvs have hardcoded paths — use PYTHONPATH approach instead
#
# Prerequisites on build machine:
#   - uv-managed Python 3.12 at ~/.local/share/uv/python/cpython-3.12.7-*/
#   - Working dev venv with funasr module at ~/3_coding/sensevoice-coreml/.venv/
#   - Apple Development certificate for code signing
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/env-xcode.sh" 2>/dev/null || true
cd "$PROJECT_DIR"

APP_NAME="ZhiYin"
BINARY_NAME="zhiyin"
BUNDLE_ID="com.zhiyin.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" ZhiYin/Sources/Info.plist)
DMG_NAME="${APP_NAME}-v${VERSION}-mac-arm64.dmg"
STAGING_DIR=".build/dmg-staging"
APP_BUNDLE="${STAGING_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
RESOURCES="${CONTENTS}/Resources"

# Python runtime (standalone, from uv)
PYTHON_SRC="$HOME/.local/share/uv/python/cpython-3.12.7-macos-aarch64-none"

echo "=== Building ${APP_NAME} v${VERSION} ==="

# ── Step 1: Build release binary ─────────────────────────────────────────────
echo "[1/7] Building Swift app + CLI (release)..."
swift build -c release 2>&1 | tail -3
swift build -c release --product zhiyin-stt 2>&1 | tail -3

RELEASE_BIN=$(swift build -c release --show-bin-path)/${BINARY_NAME}
RELEASE_CLI=$(swift build -c release --show-bin-path)/zhiyin-stt
if [ ! -f "$RELEASE_BIN" ]; then
    echo "ERROR: Release binary not found at $RELEASE_BIN"
    exit 1
fi
if [ ! -f "$RELEASE_CLI" ]; then
    echo "ERROR: CLI binary not found at $RELEASE_CLI"
    exit 1
fi
echo "  ✓ Swift binary + CLI"

# ── Step 2: Create .app bundle ───────────────────────────────────────────────
echo "[2/7] Creating app bundle..."
rm -rf "${STAGING_DIR}"
mkdir -p "${CONTENTS}/MacOS" "${RESOURCES}" "${CONTENTS}/Frameworks" "${RESOURCES}/bin"

cp "$RELEASE_BIN" "${CONTENTS}/MacOS/${BINARY_NAME}"
cp "$RELEASE_CLI" "${RESOURCES}/bin/zhiyin-stt"
install_name_tool -add_rpath @loader_path/../Frameworks "${CONTENTS}/MacOS/${BINARY_NAME}" 2>/dev/null || true
cp ZhiYin/Sources/Info.plist "${CONTENTS}/Info.plist"

if [ -f "assets/icon.icns" ]; then
    cp assets/icon.icns "${RESOURCES}/AppIcon.icns"
fi
if [ -d "ZhiYin/Sources/Resources" ]; then
    cp -R ZhiYin/Sources/Resources/* "${RESOURCES}/" 2>/dev/null || true
fi
echo "  ✓ App bundle"

# ── Step 3: Bundle Python server scripts ─────────────────────────────────────
echo "[3/7] Bundling Python server..."
cp -R python "${RESOURCES}/python"
echo "  ✓ STT server scripts"

# ── Step 4: Bundle Python 3.12 runtime ───────────────────────────────────────
echo "[4/7] Bundling Python 3.12 runtime..."
PYTHON_DEST="${RESOURCES}/python-runtime"
if [ ! -d "$PYTHON_SRC" ]; then
    echo "ERROR: Python 3.12 not found at $PYTHON_SRC"
    echo "Install with: uv python install 3.12"
    exit 1
fi

mkdir -p "$PYTHON_DEST"
# Copy bin (just python3.12 binary)
mkdir -p "$PYTHON_DEST/bin"
cp "$PYTHON_SRC/bin/python3.12" "$PYTHON_DEST/bin/python3"
# Copy lib (stdlib + dynlibs, skip include/share/tests)
cp -R "$PYTHON_SRC/lib" "$PYTHON_DEST/lib"
# Strip unnecessary stdlib parts (keep unittest — torch needs it at import)
rm -rf "$PYTHON_DEST/lib/python3.12/test" \
       "$PYTHON_DEST/lib/python3.12/tkinter" \
       "$PYTHON_DEST/lib/python3.12/idlelib" \
       "$PYTHON_DEST/lib/python3.12/ensurepip" \
       "$PYTHON_DEST/lib/python3.12/__pycache__"
echo "  ✓ Python 3.12 ($(du -sh "$PYTHON_DEST" | cut -f1))"

# ── Step 5: Bundle Python packages (slim) ────────────────────────────────────
echo "[5/7] Building slim Python packages..."
TMPVENV="/tmp/zhiyin-release-venv"
rm -rf "$TMPVENV"
"$PYTHON_SRC/bin/python3.12" -m venv "$TMPVENV"
"$TMPVENV/bin/pip" install --upgrade pip -q 2>&1 | tail -1

echo "  Installing dependencies (this takes a few minutes)..."
"$TMPVENV/bin/pip" install -q \
    "mlx-audio==0.2.10" \
    "silero-vad" \
    "opencc-python-reimplemented" \
    2>&1 | tail -3

# Ensure funasr model module exists (PyPI build may omit it)
FUNASR_MOD="$TMPVENV/lib/python3.12/site-packages/mlx_audio/stt/models/funasr"
if [ ! -d "$FUNASR_MOD" ]; then
    echo "  Patching: adding funasr model module..."
    FALLBACK_FUNASR="$HOME/3_coding/sensevoice-coreml/.venv/lib/python3.12/site-packages/mlx_audio/stt/models/funasr"
    if [ -d "$FALLBACK_FUNASR" ]; then
        cp -R "$FALLBACK_FUNASR" "$FUNASR_MOD"
    else
        echo "  ERROR: funasr module not found. Run dev build first to install it."
        exit 1
    fi
fi

# Strip unused packages (gradio, opencv, pandas, scipy, spacy, etc.)
echo "  Stripping unused packages..."
SP="$TMPVENV/lib/python3.12/site-packages"
REMOVE_DIRS=(
    # UI/demo (mlx-audio ships gradio demos — not needed for STT)
    gradio gradio_client aiofiles aiohttp aiosignal aiohappyeyeballs
    multidict yarl propcache frozenlist orjson safehttpx
    # Image/video (not needed for audio STT)
    cv2 PIL av ffmpy
    # Data analysis
    pandas pyarrow datasets pytz tzdata python_dateutil
    # NLP (we use mlx_audio tokenizer, not spacy)
    spacy spacy_curated_transformers spacy_legacy spacy_loggers
    thinc cymem preshed blis srsly weasel murmurhash confection
    curated_tokenizers curated_transformers wasabi
    # Scientific libs not needed for inference
    scipy sklearn scikit_learn numba llvmlite
    # Other heavy unused deps
    onnxruntime mistral_common babel pycountry
    mlx_vlm mlx_lm  # only mlx_audio.stt needed
    rdflib csvw isodate language_tags segments
    tiktoken sentencepiece librosa audioread pooch lazy_loader soxr
    phonemizer_fork espeakng_loader misaki pydub sounddevice
    dlinfo einops einx ruff protobuf flatbuffers omegaconf
    antlr4_python3_runtime num2words docopt groovy smart_open loguru
    jsonschema jsonschema_specifications referencing rpds_py
    multiprocess dill msgpack xxhash dacite pydantic_extra_types
    google_crc32c rfc3986 uritemplate semantic_version
    webrtcvad wrapt addict frozendict brotli ifaddr dnspython
    pyparsing pyee pylibsrtp pyopenssl cryptography
    # WebRTC/streaming
    aiortc aioice fastrtc fastrtc_moonshine_onnx
    # Dev tools not needed at runtime
    pip setuptools pygments
)
for pkg in "${REMOVE_DIRS[@]}"; do
    rm -rf "$SP/$pkg/" 2>/dev/null
    # Also remove .dist-info dirs (various naming conventions)
    find "$SP" -maxdepth 1 -type d -iname "${pkg}*dist-info" -exec rm -rf {} + 2>/dev/null || true
done

# Strip __pycache__, tests, C++ headers
find "$SP" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null
find "$SP" -type d -name "tests" -exec rm -rf {} + 2>/dev/null
find "$SP" -type d -name "test" -exec rm -rf {} + 2>/dev/null
rm -rf "$SP/torch/include/" "$SP/torch/share/"

# Copy slim site-packages into app bundle
PKGS_DEST="${RESOURCES}/python-packages"
cp -R "$SP" "$PKGS_DEST"
rm -rf "$TMPVENV"
echo "  ✓ Python packages ($(du -sh "$PKGS_DEST" | cut -f1))"

# ── Step 6: Code sign ────────────────────────────────────────────────────────
echo "[6/7] Code signing..."
ENTITLEMENTS="${PROJECT_DIR}/ZhiYin/Sources/ZhiYin.entitlements"
# Prefer Developer ID Application (for distribution), fall back to Apple Development
SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')
if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)".*/\1/')
fi
if [ -n "$SIGN_IDENTITY" ]; then
    # Sign all binaries inside the bundle (required for notarization)
    echo "  Signing embedded binaries..."
    # Sign .so and .dylib files
    find "${APP_BUNDLE}" \( -name "*.so" -o -name "*.dylib" \) -print0 | \
        xargs -0 -n1 codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp 2>/dev/null
    # Sign Mach-O executables (python3, torch binaries, etc.)
    find "${APP_BUNDLE}" -type f -perm +111 | while read -r f; do
        if file "$f" | grep -q "Mach-O"; then
            codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$f" 2>/dev/null
        fi
    done
    BIN_COUNT=$(find "${APP_BUNDLE}" \( -name "*.so" -o -name "*.dylib" \) | wc -l | tr -d ' ')
    EXEC_COUNT=$(find "${APP_BUNDLE}" -type f -perm +111 -exec file {} \; | grep -c "Mach-O")
    echo "  ✓ Signed $BIN_COUNT shared libs + $EXEC_COUNT executables"
    # Sign the main app bundle
    codesign --force --sign "$SIGN_IDENTITY" --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" --identifier "$BUNDLE_ID" "${APP_BUNDLE}"
    echo "  ✓ Signed with: $SIGN_IDENTITY"
else
    codesign --force --sign - --deep --identifier "$BUNDLE_ID" "${APP_BUNDLE}"
    echo "  ⚠ Ad-hoc signed"
fi

# ── Step 7: Create DMG with drag-to-Applications layout ──────────────────────
echo "[7/7] Creating DMG (this takes a while)..."
rm -f "${DMG_NAME}"

# Add Applications symlink for drag-to-install
ln -sf /Applications "${STAGING_DIR}/Applications"

# Create a temporary read-write DMG first (for layout customization)
TEMP_DMG="/tmp/zhiyin-temp.dmg"
rm -f "$TEMP_DMG"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov -format UDRW \
    -fs HFS+ \
    "$TEMP_DMG"

# Mount and customize Finder layout (icon positions, window size)
MOUNT_DIR=$(hdiutil attach "$TEMP_DMG" -readwrite -noverify | grep "/Volumes/" | sed 's/.*\/Volumes/\/Volumes/')
if [ -n "$MOUNT_DIR" ]; then
    # Use AppleScript to set icon positions and window appearance
    # This may timeout on headless/busy systems — that's OK, layout is cosmetic only
    if timeout 15 osascript <<'APPLESCRIPT' 2>/dev/null; then
tell application "Finder"
    tell disk "ZhiYin"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 760, 440}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 96
        set position of item "ZhiYin.app" to {140, 160}
        set position of item "Applications" to {420, 160}
        update without registering applications
        close
    end tell
end tell
APPLESCRIPT
        echo "  ✓ DMG layout customized"
        sleep 2
    else
        echo "  ⚠ Finder layout skipped (timeout) — DMG still works fine"
    fi
    hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null
fi

# Convert to compressed read-only DMG
hdiutil convert "$TEMP_DMG" -format UDZO -o "${DMG_NAME}" -ov
rm -f "$TEMP_DMG"

# ── Step 9: Notarize ─────────────────────────────────────────────────────────
NOTARY_PROFILE="zhiyin"
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "[9/9] Notarizing with Apple (this takes a few minutes)..."
    if xcrun notarytool submit "${DMG_NAME}" --keychain-profile "$NOTARY_PROFILE" --wait; then
        xcrun stapler staple "${DMG_NAME}"
        echo "  ✓ Notarized and stapled"
    else
        echo "  ⚠ Notarization failed — DMG still works but users will see Gatekeeper warning"
    fi
else
    echo "[9/9] Skipping notarization (no keychain profile '$NOTARY_PROFILE')"
    echo "  Run: xcrun notarytool store-credentials $NOTARY_PROFILE"
fi

echo ""
echo "========================================="
echo "  ✓ ${DMG_NAME}"
echo "  Size: $(du -h "${DMG_NAME}" | cut -f1)"
echo "========================================="
echo ""
echo "Python runtime + packages included. STT model downloads on first launch."
echo ""
echo "User install steps:"
echo "  1. Download and open ${DMG_NAME}"
echo "  2. Drag ZhiYin.app to /Applications"
echo "  3. Grant Microphone + Accessibility permissions when prompted"
echo "  4. First launch: model auto-downloads (~1.5GB, one-time)"
