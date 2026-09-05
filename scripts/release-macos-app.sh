#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Darwin ]]; then
    echo "Releases must be built on macOS." >&2
    exit 1
fi
case "${1:-}" in
    ""|--with-widget) ;;
    *) echo "Usage: bash scripts/release-macos-app.sh [--with-widget]" >&2; exit 1 ;;
esac
if [[ "$#" -gt 1 ]]; then
    echo "Usage: bash scripts/release-macos-app.sh [--with-widget]" >&2
    exit 1
fi
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application certificate name or SHA-1.}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to credentials saved with xcrun notarytool store-credentials.}"

bash scripts/build-macos-app.sh --release "$@"
app="$PWD/target/AI Usage.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
variant=menu-bar
if [[ "${1:-}" == --with-widget ]]; then variant=widget; fi
mkdir -p target/releases
# Keep failed notarization submissions/logs available for diagnosis. Only create
# the final archive after Apple accepts it and Gatekeeper verification succeeds.
stage="$(mktemp -d "$PWD/target/releases/submission.XXXXXX")"
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/submission.zip"
if ! xcrun notarytool submit "$stage/submission.zip" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format plist > "$stage/notarization.plist"; then
    echo "Notarization failed. Submission details: $stage/notarization.plist" >&2
    exit 1
fi
status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$stage/notarization.plist")"
if [[ "$status" != Accepted ]]; then
    submission_id="$(/usr/libexec/PlistBuddy -c 'Print :id' "$stage/notarization.plist")"
    xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" "$stage/notarization-log.json"
    echo "Notarization was $status. See $stage/notarization-log.json" >&2
    exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"
archive="$PWD/target/releases/AI-Usage-$version-macos-$(uname -m)-$variant.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/release.zip"
mv "$stage/release.zip" "$archive"
(cd "$(dirname "$archive")" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
printf 'Signed and notarized release: %s\n' "$archive"
