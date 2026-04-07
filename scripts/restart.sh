#!/bin/bash
# Restart ZhiYin-Dev.app (without rebuilding) with console output
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_BUNDLE="$PROJECT_DIR/.build/ZhiYin-Dev.app"

# Kill ALL existing zhiyin processes (app + python server)
pkill -f zhiyin 2>/dev/null || true
# Kill any process occupying the STT server port
lsof -ti:17760 | xargs kill 2>/dev/null || true
sleep 1

echo "========================================="
echo "  ZhiYin Restart — Console Mode"
echo "  Ctrl+C to quit"
echo "========================================="

cleanup() {
    echo ""
    echo "Shutting down..."
    pkill -f "stt_server.py" 2>/dev/null || true
    exit 0
}
trap cleanup INT TERM

exec "$APP_BUNDLE/Contents/MacOS/zhiyin"
