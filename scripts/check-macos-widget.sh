#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p target/widget-check target/swift-module-cache
swift_flags=(-swift-version 5 -parse-as-library -module-cache-path "$PWD/target/swift-module-cache" -target "$(uname -m)-apple-macosx14.0")
xcrun swiftc "${swift_flags[@]}" macos/SharedUsage.swift macos/Tests/SharedUsageTests.swift \
    -o target/widget-check/shared-usage-tests
target/widget-check/shared-usage-tests
for mode in menu-bar widget; do
    test_flags=(-D APP_DELEGATE_TESTING)
    if [[ "$mode" == widget ]]; then
        test_flags+=(-D WIDGET_ENABLED)
    fi
    xcrun swiftc "${swift_flags[@]}" "${test_flags[@]}" -framework AppKit \
        macos/SharedUsage.swift macos/AIUsage.swift macos/Tests/AppDelegateLaunchTests.swift \
        -o "target/widget-check/launch-tests-$mode"
    "target/widget-check/launch-tests-$mode"
done
xcrun swiftc "${swift_flags[@]}" -D WIDGET_ENABLED -framework AppKit -framework WidgetKit \
    macos/SharedUsage.swift macos/AIUsage.swift -o target/widget-check/AIUsage
xcrun swiftc "${swift_flags[@]}" -application-extension -framework SwiftUI -framework WidgetKit \
    -Xlinker -e -Xlinker _NSExtensionMain \
    macos/SharedUsage.swift macos/Widget/AIUsageWidget.swift -o target/widget-check/AIUsageWidget
plutil -lint macos/Info.plist macos/Widget/Info.plist
echo "Widget and host compiled for macOS 14+. Signing and widget gallery checks require an Apple signing identity."
