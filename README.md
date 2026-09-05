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

## Development

```sh
cargo fmt --check
cargo test
cargo clippy --all-targets -- -D warnings
```

Unit tests cover quota selection, legacy fallback behavior, and output
formatting without starting Codex or requiring an account.
