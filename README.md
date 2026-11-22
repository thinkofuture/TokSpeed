<p align="center">
  <img src="Resources/AppIcon.png" alt="TokSpeed logo" width="120" />
</p>

<h1 align="center">TokSpeed</h1>

<p align="center">
  <strong>Your AI's pace, at a glance.</strong><br>
  Lightweight macOS menu bar app showing token generation speed for Codex, OpenCode, Claude Code, Antigravity, Hermes, and Cursor.
</p>

<p align="center">
  Reads local logs only — no API key, no uploads, no network requests.
</p>

<br>

---

<br>

## Build & Run

Requires macOS 13+ and Xcode Command Line Tools.

```sh
bash scripts/build.sh
open build/TokSpeed.app
```

## OpenCode speed

For each completed OpenCode V2 model call, TokSpeed divides output tokens by the time from first token to stream end, excluding both the initial wait and post-stream cleanup. The stream must be within the call's start and completion times, last at least 0.12 s, and yield at most 3,000 tok/s. If stream timing is missing or invalid, or the database uses the V1 schema, TokSpeed uses the call's start-to-completion time instead.

The history and `build/TokSpeed.app/Contents/MacOS/TokSpeed --once --source opencode` use the same per-call calculation. During a turn, speed is total output tokens divided by the sum of those measured durations for completed calls only. It does not count time between calls (such as tool execution) or estimate speed from a partial stream.

## Antigravity speed

TokSpeed reads local Antigravity desktop and `agy` CLI conversation databases. The card highlights the most recently active conversation and updates when Antigravity records usable model-call telemetry for that turn. Until then the menu bar shows elapsed seconds (with `s` even in **Number only** mode). History from another conversation is never used as the active speed. There is no per-token feed: the number only changes when the database provides new measurements.

Like the `antigravity-codex-theme` input indicator, TokSpeed uses output tokens divided by streaming time when the stream lasts at least 0.12 s and the result is greater than 0 and at most 3,000 tok/s. Otherwise it divides by time to first token (TTFT) plus streaming time. The trend only includes completed measurements. `build/TokSpeed.app/Contents/MacOS/TokSpeed --once --source antigravity` reports the measurement basis (including **E2E fallback**), end-to-end rate, total elapsed time and TTFT. The one-second refresh checks database and WAL changes without decoding unchanged files.

## Hermes speed

TokSpeed works without setup using completed calls from Hermes's `logs/agent.log`. Optional: install the bundled Hermes user plugin for better timing on **new** calls:

```sh
TPS=build/TokSpeed.app/Contents/MacOS/TokSpeed
"$TPS" --install-hermes-plugin
hermes plugins enable tokspeed-metrics
# After completing a Hermes reply:
"$TPS" --once --source hermes
```

The installer only copies the plugin files; it does not edit Hermes's configuration or reload a service. Hermes's own `plugins enable` command opts the plugin in and may reload a compatible running gateway. If it doesn't, start a new Hermes process, or reload/restart your gateway when convenient. Disable with `hermes plugins disable tokspeed-metrics` and reload if needed. Use the same `HERMES_HOME` for installation, Hermes, and TokSpeed (default `~/.hermes`); when using a named profile, point TokSpeed at that profile's actual home.

For a completed call with reported usage and valid epoch-second timing, TokSpeed divides output tokens by the time from the first chunk to API completion. It accepts spans of at least 0.12 s and rates up to 3,000 tok/s. This is an estimate, not live decoding speed: the first chunk needn't contain visible text, reported output can include reasoning, and API completion can include trailing processing. Non-streaming and unsupported providers or Hermes builds fall back to full API time (hook, or rounded legacy log latency). Missing usage cannot yield a sample. The CLI labels the basis and shows time to first chunk when the estimate is used.

The plugin stores only timing, token counts, model/provider labels, and hashed session/request IDs in two bounded local files under `$HERMES_HOME/plugin-data/tokspeed-metrics/`. It records no prompts, replies, tool arguments, URLs, or credentials and makes no network requests. Hook rows are deduplicated by session/request ID. Legacy log lines have no matching request ID, so TokSpeed replaces only an unambiguous nearby match; ambiguous or unmatched legacy lines stay as fallback history. Delivery is best-effort: concurrent writes or a filesystem error can leave a call to the legacy fallback.

## Cursor speed

Cursor remains a whole-turn measurement: recorded output tokens divided by the time from prompt submit to loop stop, including thinking, tools and waiting. Its hook and database don't provide a verified first-chunk timestamp. The menu bar shows elapsed time during a turn.

## License

[MIT License](LICENSE)
