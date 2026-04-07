#!/bin/bash
# Use full Xcode when available (avoids "xcodebuild requires Xcode" when only CLT is active).
# Source this before building, or export DEVELOPER_DIR in your shell.
if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
