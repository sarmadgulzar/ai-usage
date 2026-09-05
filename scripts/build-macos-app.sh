#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "The menu bar app requires macOS." >&2
    exit 1
fi

codex_executable="$(command -v "${CODEX_BIN:-codex}" || true)"
if [[ -z "$codex_executable" || ! -x "$codex_executable" ]]; then
    echo "Install Codex CLI or set CODEX_BIN to its executable path, then run this script again." >&2
    exit 1
fi
# Store an absolute path so Finder launches also work with a relative override.
codex_executable="$(cd "$(dirname "$codex_executable")" && pwd)/$(basename "$codex_executable")"

cargo build --release --target-dir target
app="$PWD/target/AI Usage.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$PWD/target/swift-module-cache"
xcrun swiftc -O -swift-version 5 -module-cache-path "$PWD/target/swift-module-cache" \
    -framework AppKit macos/AIUsage.swift -o "$app/Contents/MacOS/AIUsage"
cp target/release/ai-usage "$app/Contents/MacOS/ai-usage"
cp macos/Info.plist "$app/Contents/Info.plist"
cp macos/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
printf '%s\n' "$codex_executable" > "$app/Contents/Resources/codex-path.txt"
codesign --force --deep --sign - "$app"
printf 'Built %s\nLaunch with: open "%s"\n' "$app" "$app"
