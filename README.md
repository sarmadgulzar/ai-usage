# AI Usage Utility

Track your ChatGPT account's remaining Codex allowance (5-hour and weekly) from the terminal, macOS menu bar, or an optional desktop widget.

## Setup

Requires Codex CLI and an authenticated account:

```sh
codex login
```

To use a signed release, unzip the build matching your Mac's architecture, move **AI Usage.app** to Applications, and open it. Requires macOS 14+; Rust and Xcode are not needed.

## Run from source

Requires Rust/Cargo. Building the macOS app also requires Xcode Command Line Tools (`xcode-select --install`).

```sh
cargo run --release          # Remaining allowance and local reset times
cargo run --release -- --json # Full rate-limit response
```

### Menu bar app

```sh
bash scripts/build-macos-app.sh
open "target/AI Usage.app"
```

Shows remaining allowances and refreshes every minute. Click for reset times and **Refresh Now**. Copy the app to Applications and add it under **System Settings → General → Login Items** to start at login.

### Optional widget

Requires macOS 14+, a macOS 14+ SDK, and an Apple Development or Developer ID Application signing identity.

```sh
security find-identity -v -p codesigning
SIGNING_IDENTITY="Your signing identity" bash scripts/build-macos-app.sh --with-widget
```

Quit the old app, copy `target/AI Usage.app` to Applications, and open it. Right-click the desktop → **Edit Widgets** → **AI Usage**. Keep the menu bar app running for updates; macOS may delay widget refreshes.

If replacing an existing widget build, run `pkill -x AIUsageWidget || true` before reopening the app.

## Development

```sh
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
bash scripts/check-macos-widget.sh # Requires macOS 14+ SDK
```
