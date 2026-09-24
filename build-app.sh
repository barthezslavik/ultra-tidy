#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$PWD/target}"
export CLANG_MODULE_CACHE_PATH="$CARGO_TARGET_DIR/clang-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$CARGO_TARGET_DIR/swift-module-cache"
cargo build --release

app="dist/Ultra Tidy.app"
mkdir -p "$app/Contents/MacOS"
cp macos/Info.plist "$app/Contents/Info.plist"
swiftc -swift-version 5 -O -parse-as-library \
    -module-cache-path "$CARGO_TARGET_DIR/swift-module-cache" \
    -o "$app/Contents/MacOS/Ultra Tidy" \
    macos/UltraTidyApp.swift \
    -L "$CARGO_TARGET_DIR/release" -l ultra_tidy_core \
    -framework Photos -framework AppKit -framework SwiftUI
codesign --force --sign - "$app"
print "Built $app"
