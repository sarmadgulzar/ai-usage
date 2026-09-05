# AI Usage Utility

Reads the Codex allowance associated with your ChatGPT account through the local App Server protocol.

## Run

Prerequisites: Rust/Cargo and Codex CLI installed on your Mac.

```sh
codex login
codex login status
cargo run --release
```

Output has one line each for `5-hour` and `Weekly`, with the remaining
percentage and reset date/time in your Mac's local timezone. Missing windows
or fields are displayed as unavailable, never assumed to be unused.

To inspect the full rate-limit result, including any additional buckets:

```sh
cargo run --release -- --json
```

To run the compiled executable directly:

```sh
./target/release/ai-usage
```

## macOS menu bar

Build and launch the native menu bar app (requires Xcode Command Line Tools,
installed with `xcode-select --install`, plus the prerequisites above):

```sh
bash scripts/build-macos-app.sh
open "target/AI Usage.app"
```

The menu bar shows `AI 5h 88% · W 62%`: the remaining 5-hour and weekly
allowances, rounded to whole percentages. Click it for precise percentages,
local reset times, the last update time, **Refresh Now**, and **Quit AI Usage**.
It fetches immediately, every 60 seconds, and on wake. Fetches run in the
background and never overlap. Missing percentages appear as `—`; failed
refreshes show a warning and mark any previous values as stale. **Show Error…**
provides diagnostics, and the next scheduled refresh retries automatically.

The app runs without a Dock icon. You can copy `target/AI Usage.app` into
Applications; to start it at login, add the copied app under **System Settings →
General → Login Items**. Quit the app before rebuilding or replacing it.

The bundle includes the Rust reader. Local builds record the current Codex CLI
path as a hint; if it moves, the app searches Homebrew locations and its PATH.
Release builds discover Codex on the recipient's Mac. To use
a specific CLI executable, build with `CODEX_BIN=/absolute/path/to/codex bash
scripts/build-macos-app.sh`. The app uses your existing Codex login.

`--menu-bar-json` outputs the compact title, detail lines, and structured
`fiveHour` / `weekly` values (`remainingPercent` and Unix `resetsAt`, each nullable)
used by the native app and widget; `--json` continues to output the full rate-limit result.

## macOS widget

The optional WidgetKit extension supports small and medium widgets on the
desktop and in Notification Center on **macOS 14 or later**. Both sizes show the
remaining 5-hour and weekly allowances; the medium size also shows local reset
times. Click the widget to open AI Usage and request a refresh.

The widget reads an atomic cache written by the running menu bar app. Keep
AI Usage running (optionally as a Login Item) for updates. It never reads your
Codex credentials or launches the CLI itself. Missing values display as `—`.
Failed fetches preserve the previous values and mark them stale; cached data
also becomes stale after five minutes or when a quota reset passes. The app
requests a widget update after every successful fetch (normally once a minute),
even when the quota percentages are unchanged. **Refresh Now**, clicking the
widget, and waking the Mac also explicitly request a widget reload. The widget
requests a fallback cache reload after five minutes. macOS controls when these
requests appear onscreen, so widgets may lag behind the menu bar.

The widget build requires an **Apple Development or Developer ID Application
signing identity** in your keychain and a macOS 14+ SDK. In Xcode, configure your
Apple account and signing certificate under **Settings → Accounts**. List
available identities, then build with the exact name or SHA-1:

```sh
security find-identity -v -p codesigning
SIGNING_IDENTITY="Apple Development: Your Name (CERTIFICATE_ID)" \
  bash scripts/build-macos-app.sh --with-widget
```

The build derives your team ID from the certificate and signs the host and
sandboxed extension with the shared app group
`TEAMID.com.sarmadgulzar.ai-usage`. This macOS team-prefixed app group does not
require a provisioning profile; see Apple's
[app group requirements](https://developer.apple.com/documentation/xcode/accessing-app-group-containers).
Ad-hoc signing is supported only by the menu bar build; the widget build stops
early without a signing identity. These are local builds, not notarized releases.

Quit the old app, copy `target/AI Usage.app` into Applications, then restart
the separate widget process before opening the new app:

```sh
pkill -x AIUsageWidget || true
open "/Applications/AI Usage.app"
```

Quitting the menu bar app alone doesn't stop its widget extension. If the old
extension stays alive after replacement, it can produce timelines that macOS
cannot display, leaving a loading placeholder. Restarting it lets macOS launch
the newly installed extension. `pkill` finding no running widget is harmless.

Right-click the desktop → **Edit Widgets**, search for **AI Usage**, and choose
small or medium. If the widget is empty, click it and check the menu bar for a
fetch error or **Widget sync failed** (hover for diagnostics). If it does not
appear in the gallery, check that you installed the `--with-widget` build and
launched that copy. Rebuilding without the flag produces the menu bar app only.

To test the cache and compile both Swift targets without a signing identity:

```sh
bash scripts/check-macos-widget.sh
```

## Signed releases

Public releases require a **Developer ID Application** certificate and its
private key in your keychain. An Apple Development certificate cannot be used
for notarization. In Xcode, use **Settings → Accounts → your team → Manage
Certificates → + → Developer ID Application**.

Save notarization credentials using Terminal's private interactive prompts
(use an Apple app-specific password when prompted for an Apple ID password):

```sh
xcrun notarytool store-credentials "ai-usage-notary"
security find-identity -v -p codesigning
```

Build, sign, notarize, staple, and verify a release, including the widget:

```sh
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="ai-usage-notary" \
  bash scripts/release-macos-app.sh --with-widget
```

Omit `--with-widget` for a menu bar only release. The script signs all embedded
code with hardened runtime and secure timestamps, checks Apple's acceptance,
and verifies the stapled app with Gatekeeper before producing a final ZIP and
SHA-256 checksum under `target/releases/`. Submission results are retained there
for troubleshooting. It does not publish to GitHub automatically.

These releases require **macOS 14+** and target the build Mac's architecture
(`arm64` for Apple Silicon or `x86_64` for Intel); the ZIP filename identifies it.
Build on each architecture to publish both. To prepare a signed app without
submitting it to Apple, use `SIGNING_IDENTITY="..." bash
scripts/build-macos-app.sh --release --with-widget`.

Recipients unzip the matching release, move **AI Usage.app** into Applications,
and open it. They need Codex CLI installed (standard Homebrew locations are
detected when launched from Finder) and must run `codex login` using their own
ChatGPT account. Rust, Xcode, and signing certificates are not required to run
the downloaded app. Nonstandard CLI locations can be supplied with `CODEX_BIN`
when launching the app's executable from Terminal. Follow the widget section
above to add the desktop widget.

See Apple's [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Development

```sh
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
bash scripts/check-macos-widget.sh # macOS 14+ SDK
```

Unit tests cover quota selection, legacy fallback behavior, and output
formatting without starting Codex or requiring an account.
