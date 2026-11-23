<p align="center">
  <img src="Resources/AppIcon.png" alt="TokSpeed logo" width="120" />
</p>

<h1 align="center">TokSpeed</h1>

<p align="center">
  <strong>Your AI's pace, at a glance.</strong><br>
  Lightweight macOS menu bar app showing token generation speed for Codex, OpenCode, Claude Code, Antigravity, Hermes, Cursor, and T3 Code.
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

The menu chart considers up to 60 completed calls per visible tool on a shared speed scale. Bright lines for active tools share a timeline covering up to six hours before the latest active completion. Faint lines for idle tools show up to six hours before each tool’s own last completion, even if it happened days ago. A faint line’s horizontal position does not indicate that it happened at the same time as another line. The curves use representative measurements where calls are crowded, preserve gaps longer than 20 minutes, and stop at each tool’s last call. The chart omits isolated readings at least four times as fast as both nearby neighbors, without changing the underlying measurements or capping speeds. Hover near a plotted point to see its tool, recorded speed, and completion time in the app’s language. Today’s readings show the time to the minute; older readings also show the date. The numbers below show current-turn speed when available, or the last completed speed otherwise. Drag the logos left or right to reorder them. Settings and Quit are in the bottom-right corner.

## OpenCode speed

In **Settings → Panel view**, switch between the default combined chart and the classic per-agent list. The classic list shows the logo, name, recent trend, and speed in each row. Both views keep Settings and Quit in the bottom-right corner and share the same agent order.

For each completed OpenCode V2 model call, TokSpeed divides output tokens by the time from first token to stream end, excluding both the initial wait and post-stream cleanup. The stream must be within the call's start and completion times, last at least 0.12 s, and yield at most 3,000 tok/s. If stream timing is missing or invalid, or the database uses the V1 schema, TokSpeed uses the call's start-to-completion time instead.

The history and `build/TokSpeed.app/Contents/MacOS/TokSpeed --once --source opencode` use the same per-call calculation. During a turn, speed is total output tokens divided by the sum of those measured durations for completed calls only. It does not count time between calls (such as tool execution) or estimate speed from a partial stream.

## Antigravity speed

TokSpeed reads local Antigravity desktop and `agy` CLI conversation databases. The panel displays the most recently active conversation's speed and updates when Antigravity records usable model-call telemetry for that turn. Until then the menu bar shows elapsed seconds (with `s` even in **Number only** mode). History from another conversation is never used as the active speed. There is no per-token feed: the number only changes when the database provides new measurements.

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

## T3 Code speed

TokSpeed reads T3 Code's local V2 SQLite database (`$T3CODE_HOME/userdata/statev2.sqlite`, default `~/.t3/userdata/statev2.sqlite`) in read-only mode. Completed turns report output tokens divided by full turn duration (including tools and waiting). While a turn is running, the menu bar shows elapsed time. Verify locally with `build/TokSpeed.app/Contents/MacOS/TokSpeed --once --source t3code`.

## License

[MIT License](LICENSE)
