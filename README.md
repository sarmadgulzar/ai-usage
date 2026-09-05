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

The bundle includes the Rust reader and records the current Codex CLI path so
it also works when opened from Finder. If Codex moves, rebuild the app. To use
a specific CLI executable, build with `CODEX_BIN=/absolute/path/to/codex bash
scripts/build-macos-app.sh`. The app uses your existing Codex login.

`--menu-bar-json` outputs the compact title and detail lines used by the native
app; `--json` continues to output the full rate-limit result.

## Development

```sh
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
```

Unit tests cover quota selection, legacy fallback behavior, and output
formatting without starting Codex or requiring an account.
