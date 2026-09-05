#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "The menu bar app requires macOS." >&2
    exit 1
fi

with_widget=false
release=false
for argument in "$@"; do
    case "$argument" in
        --with-widget) with_widget=true ;;
        --release) release=true ;;
        *) echo "Usage: bash scripts/build-macos-app.sh [--with-widget] [--release]" >&2; exit 1 ;;
    esac
done
identity="${SIGNING_IDENTITY:--}"
sign_flags=(--force --sign "$identity")
if [[ "$release" == true ]]; then
    # Accept a certificate name or SHA-1, but never a development/ad-hoc identity.
    if ! security find-identity -v -p codesigning | awk -v identity="$identity" \
        'index($0, "\"Developer ID Application:") && ($2 == identity || index($0, "\"" identity "\"")) { found=1 } END { exit !found }'; then
        echo "A release requires SIGNING_IDENTITY matching a valid Developer ID Application certificate in your keychain." >&2
        exit 1
    fi
    sign_flags+=(--options runtime --timestamp)
fi
if [[ "$with_widget" == true && ( -z "${SIGNING_IDENTITY:-}" || "${SIGNING_IDENTITY:-}" == "-" ) ]]; then
    echo "A widget needs an Apple signing identity for its shared app group." >&2
    echo "Set SIGNING_IDENTITY to a name or SHA-1 from: security find-identity -v -p codesigning" >&2
    exit 1
fi

if [[ "$release" == false ]]; then
    codex_executable="$(command -v "${CODEX_BIN:-codex}" || true)"
    if [[ -z "$codex_executable" || ! -x "$codex_executable" ]]; then
        echo "Install Codex CLI or set CODEX_BIN to its executable path, then run this script again." >&2
        exit 1
    fi
    # Local builds retain explicit/nonstandard installations as a hint.
    codex_executable="$(cd "$(dirname "$codex_executable")" && pwd)/$(basename "$codex_executable")"
fi

cargo build --locked --release --target-dir target
# Stage a fresh bundle so switching modes cannot leave an old extension or
# signature behind, and a failed compile doesn't damage the previous build.
build_stage="$(mktemp -d "$PWD/target/macos-build.XXXXXX")"
trap 'rm -rf "$build_stage"' EXIT
app="$build_stage/AI Usage.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$PWD/target/swift-module-cache"
swift_flags=(-O -swift-version 5 -parse-as-library -module-cache-path "$PWD/target/swift-module-cache")
if [[ "$with_widget" == true || "$release" == true ]]; then
    swift_flags+=(-target "$(uname -m)-apple-macosx14.0")
fi
if [[ "$with_widget" == true ]]; then
    swift_flags+=(-D WIDGET_ENABLED)
fi
xcrun swiftc "${swift_flags[@]}" -framework AppKit \
    macos/SharedUsage.swift macos/AIUsage.swift -o "$app/Contents/MacOS/AIUsage"
cp target/release/ai-usage "$app/Contents/MacOS/ai-usage"
cp macos/Info.plist "$app/Contents/Info.plist"
cp macos/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
if [[ "$release" == false ]]; then
    printf '%s\n' "$codex_executable" > "$app/Contents/Resources/codex-path.txt"
fi
if [[ "$with_widget" == true || "$release" == true ]]; then
    /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 14.0" "$app/Contents/Info.plist"
fi
codesign "${sign_flags[@]}" "$app/Contents/MacOS/ai-usage"

if [[ "$with_widget" == true ]]; then
    # Derive the group from the actual certificate, avoiding mismatched team IDs.
    signing_info="$(codesign -dv "$app/Contents/MacOS/ai-usage" 2>&1)"
    team_id="$(sed -n 's/^TeamIdentifier=//p' <<< "$signing_info")"
    if [[ ! "$team_id" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "SIGNING_IDENTITY must be an Apple certificate with a valid team identifier." >&2
        exit 1
    fi
    app_group="$team_id.com.sarmadgulzar.ai-usage"
    widget="$app/Contents/PlugIns/AIUsageWidget.appex"
    mkdir -p "$widget/Contents/MacOS"
    # Match Xcode's macOS extension entry point. Starting at Swift's plain main
    # returns before serving WidgetKit's XPC requests on current macOS releases.
    xcrun swiftc "${swift_flags[@]}" -application-extension -framework SwiftUI -framework WidgetKit \
        -Xlinker -e -Xlinker _NSExtensionMain \
        macos/SharedUsage.swift macos/Widget/AIUsageWidget.swift -o "$widget/Contents/MacOS/AIUsageWidget"
    cp macos/Widget/Info.plist "$widget/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :AIUsageAppGroup string $app_group" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :AIUsageAppGroup string $app_group" "$widget/Contents/Info.plist"

    for kind in app widget; do
        entitlements="$build_stage/$kind.entitlements"
        /usr/libexec/PlistBuddy -c 'Clear dict' "$entitlements" >/dev/null
        /usr/libexec/PlistBuddy -c 'Add :com.apple.security.application-groups array' "$entitlements"
        /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string $app_group" "$entitlements"
    done
    /usr/libexec/PlistBuddy -c 'Add :com.apple.security.app-sandbox bool true' "$build_stage/widget.entitlements"
    codesign "${sign_flags[@]}" --entitlements "$build_stage/widget.entitlements" "$widget"
    codesign "${sign_flags[@]}" --entitlements "$build_stage/app.entitlements" "$app"
else
    codesign "${sign_flags[@]}" "$app"
fi
codesign --verify --deep --strict "$app"
rm -rf "$PWD/target/AI Usage.app"
mv "$app" "$PWD/target/AI Usage.app"
app="$PWD/target/AI Usage.app"
printf 'Built %s\nLaunch with: open "%s"\n' "$app" "$app"
if [[ "$with_widget" == true ]]; then
    echo "Quit AI Usage and copy the app to Applications. After replacing it, run: pkill -x AIUsageWidget"
    echo "Then open AI Usage. Use Edit Widgets and search for AI Usage to add the widget."
fi
