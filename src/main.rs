use std::fmt::Display;
use std::process::Stdio;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use chrono::{DateTime, Local, TimeZone, Utc};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{ChildStdin, ChildStdout, Command};
use tokio::time::timeout;

const RESPONSE_TIMEOUT: Duration = Duration::from_secs(30);
const FIVE_HOUR_MINUTES: u64 = 300;
const WEEKLY_MINUTES: u64 = 10_080;

async fn send_message(input: &mut ChildStdin, message: Value) -> Result<()> {
    let mut bytes = serde_json::to_vec(&message)?;
    bytes.push(b'\n');
    input.write_all(&bytes).await?;
    input.flush().await?;
    Ok(())
}

async fn read_response(lines: &mut Lines<BufReader<ChildStdout>>, id: u64) -> Result<Value> {
    // One deadline for the whole request, even if notifications keep arriving.
    timeout(RESPONSE_TIMEOUT, async {
        while let Some(line) = lines.next_line().await? {
            let message: Value =
                serde_json::from_str(&line).context("Invalid JSON from codex app-server")?;
            if message.get("id").and_then(Value::as_u64) != Some(id) {
                continue;
            }
            if let Some(error) = message.get("error") {
                bail!("Codex returned: {error}");
            }
            return message
                .get("result")
                .cloned()
                .ok_or_else(|| anyhow!("Response has no result"));
        }
        bail!("Codex closed stdout before replying")
    })
    .await
    .with_context(|| {
        format!(
            "Codex request timed out after {} seconds",
            RESPONSE_TIMEOUT.as_secs()
        )
    })?
}

async fn fetch_rate_limits() -> Result<Value> {
    // CODEX_BIN can be an absolute executable path for a macOS GUI app.
    let executable = std::env::var_os("CODEX_BIN").unwrap_or_else(|| "codex".into());
    let mut child = Command::new(executable)
        .arg("app-server")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .context("Cannot start Codex. Install Codex CLI and run `codex login` first.")?;
    let mut input = child.stdin.take().context("Missing stdin")?;
    let mut lines = BufReader::new(child.stdout.take().context("Missing stdout")?).lines();

    let result = async {
        send_message(
            &mut input,
            json!({
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "rust_usage",
                        "version": env!("CARGO_PKG_VERSION")
                    }
                }
            }),
        )
        .await?;
        read_response(&mut lines, 1).await?;
        send_message(&mut input, json!({"method": "initialized", "params": {}})).await?;
        send_message(
            &mut input,
            json!({"id": 2, "method": "account/rateLimits/read"}),
        )
        .await?;
        read_response(&mut lines, 2).await
    }
    .await;

    // Stop and reap the process on success and on protocol errors.
    drop(input);
    let _ = child.kill().await;
    let _ = child.wait().await;
    result
}

fn codex_bucket(result: &Value) -> Option<&Value> {
    if let Some(bucket) = result
        .pointer("/rateLimitsByLimitId/codex")
        .filter(|bucket| bucket.is_object())
    {
        return Some(bucket);
    }

    result.get("rateLimits").filter(|bucket| {
        bucket.is_object()
            && bucket
                .get("limitId")
                .and_then(Value::as_str)
                .is_none_or(|id| id == "codex")
    })
}

fn find_window(bucket: &Value, minutes: u64) -> Option<&Value> {
    ["primary", "secondary"]
        .into_iter()
        .filter_map(|key| bucket.get(key))
        .find(|window| window.get("windowDurationMins").and_then(Value::as_u64) == Some(minutes))
}

fn format_window<Tz: TimeZone>(window: Option<&Value>, label: &str, timezone: &Tz) -> String
where
    Tz::Offset: Display,
{
    let Some(window) = window else {
        return format!("{label}: unavailable");
    };

    let remaining = window
        .get("usedPercent")
        .and_then(Value::as_f64)
        .map(|used| format!("{:.1}% remaining", (100.0 - used).clamp(0.0, 100.0)))
        .unwrap_or_else(|| "remaining usage unavailable".into());
    let reset = window
        .get("resetsAt")
        .and_then(Value::as_i64)
        .and_then(|seconds| DateTime::<Utc>::from_timestamp(seconds, 0))
        .map(|date| {
            date.with_timezone(timezone)
                .format("%Y-%m-%d %H:%M:%S %:z")
                .to_string()
        })
        .unwrap_or_else(|| "unavailable".into());

    format!("{label}: {remaining}; resets {reset}")
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let result = fetch_rate_limits().await?;
    if std::env::args().any(|arg| arg == "--json") {
        println!("{}", serde_json::to_string_pretty(&result)?);
        return Ok(());
    }

    let bucket = codex_bucket(&result).context(
        "No Codex quota returned. Check `codex login status`; use --json to inspect all buckets.",
    )?;
    for (minutes, label) in [(FIVE_HOUR_MINUTES, "5-hour"), (WEEKLY_MINUTES, "Weekly")] {
        let window = find_window(bucket, minutes);
        println!("{}", format_window(window, label, &Local));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;

    #[test]
    fn named_codex_bucket_takes_precedence_over_legacy_bucket() {
        let result = json!({
            "rateLimitsByLimitId": {
                "codex": {"primary": {"usedPercent": 20}}
            },
            "rateLimits": {"limitId": "codex", "primary": {"usedPercent": 80}}
        });

        assert_eq!(
            codex_bucket(&result),
            result.pointer("/rateLimitsByLimitId/codex")
        );
    }

    #[test]
    fn missing_or_non_object_named_bucket_falls_back_to_legacy() {
        let mut result = json!({"rateLimits": {"limitId": "codex"}});
        assert_eq!(codex_bucket(&result), result.get("rateLimits"));

        for invalid_bucket in [Value::Null, json!([]), json!("invalid"), json!(42)] {
            result["rateLimitsByLimitId"] = json!({"codex": invalid_bucket});
            assert_eq!(codex_bucket(&result), result.get("rateLimits"));
        }
    }

    #[test]
    fn legacy_bucket_preserves_permissive_limit_id_handling() {
        for bucket in [
            json!({}),
            json!({"limitId": "codex"}),
            json!({"limitId": null}),
            json!({"limitId": 42}),
        ] {
            let result = json!({"rateLimits": bucket});
            assert_eq!(codex_bucket(&result), result.get("rateLimits"));
        }
    }

    #[test]
    fn missing_invalid_or_unrelated_legacy_bucket_is_rejected() {
        assert!(codex_bucket(&json!({})).is_none());

        for bucket in [
            Value::Null,
            json!([]),
            json!("invalid"),
            json!({"limitId": "other"}),
        ] {
            let result = json!({"rateLimits": bucket});
            assert!(codex_bucket(&result).is_none(), "{result}");
        }
    }

    #[test]
    fn windows_are_identified_by_duration_not_position() {
        let bucket = json!({
            "primary": {"windowDurationMins": 10080},
            "secondary": {"windowDurationMins": 300}
        });

        assert_eq!(
            find_window(&bucket, FIVE_HOUR_MINUTES),
            bucket.get("secondary")
        );
        assert_eq!(find_window(&bucket, WEEKLY_MINUTES), bucket.get("primary"));
    }

    #[test]
    fn primary_window_wins_when_durations_match() {
        let bucket = json!({
            "primary": {"windowDurationMins": 300, "usedPercent": 20},
            "secondary": {"windowDurationMins": 300, "usedPercent": 80}
        });

        assert_eq!(
            find_window(&bucket, FIVE_HOUR_MINUTES),
            bucket.get("primary")
        );
    }

    #[test]
    fn invalid_window_durations_are_skipped() {
        for primary in [
            Value::Null,
            json!({}),
            json!({"windowDurationMins": null}),
            json!({"windowDurationMins": "300"}),
            json!({"windowDurationMins": -300}),
        ] {
            let bucket = json!({
                "primary": primary,
                "secondary": {"windowDurationMins": 300}
            });
            assert_eq!(
                find_window(&bucket, FIVE_HOUR_MINUTES),
                bucket.get("secondary")
            );
        }
    }

    #[test]
    fn missing_or_unrelated_windows_are_not_selected() {
        for bucket in [
            json!({}),
            json!({"primary": null}),
            json!({"primary": {"windowDurationMins": 60}}),
        ] {
            assert!(
                find_window(&bucket, FIVE_HOUR_MINUTES).is_none(),
                "{bucket}"
            );
        }
    }

    #[test]
    fn missing_windows_are_formatted_as_unavailable() {
        assert_eq!(format_window(None, "5-hour", &Utc), "5-hour: unavailable");
        assert_eq!(format_window(None, "Weekly", &Utc), "Weekly: unavailable");
    }

    #[test]
    fn window_formatting_rounds_usage_and_uses_the_given_timezone() {
        let window = json!({"usedPercent": 12.34, "resetsAt": 0});

        for (offset_seconds, expected_reset) in [
            (7200, "1970-01-01 02:00:00 +02:00"),
            (-18000, "1969-12-31 19:00:00 -05:00"),
        ] {
            let timezone = FixedOffset::east_opt(offset_seconds).unwrap();
            assert_eq!(
                format_window(Some(&window), "5-hour", &timezone),
                format!("5-hour: 87.7% remaining; resets {expected_reset}")
            );
        }
    }

    #[test]
    fn missing_or_invalid_usage_does_not_hide_the_reset_time() {
        for mut window in [
            json!({}),
            json!({"usedPercent": null}),
            json!({"usedPercent": "0"}),
            json!({"usedPercent": true}),
        ] {
            window["resetsAt"] = json!(0);
            assert_eq!(
                format_window(Some(&window), "Weekly", &Utc),
                "Weekly: remaining usage unavailable; resets 1970-01-01 00:00:00 +00:00"
            );
        }
    }

    #[test]
    fn remaining_percentage_is_clamped_to_zero_through_one_hundred() {
        for (used, expected_remaining) in [
            (-10.0, "100.0"),
            (0.0, "100.0"),
            (100.0, "0.0"),
            (110.0, "0.0"),
        ] {
            let window = json!({"usedPercent": used});
            assert_eq!(
                format_window(Some(&window), "5-hour", &Utc),
                format!("5-hour: {expected_remaining}% remaining; resets unavailable")
            );
        }
    }

    #[test]
    fn invalid_reset_times_do_not_hide_remaining_usage() {
        for reset in [
            Value::Null,
            json!("0"),
            json!(0.5),
            json!(true),
            json!(i64::MIN),
            json!(i64::MAX),
        ] {
            let window = json!({"usedPercent": 25, "resetsAt": reset});
            assert_eq!(
                format_window(Some(&window), "Weekly", &Utc),
                "Weekly: 75.0% remaining; resets unavailable"
            );
        }
    }
}
