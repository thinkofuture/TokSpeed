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

## Build, Test & Run

Requires macOS 13+ and Swift 5.9 or later (Xcode Command Line Tools).

```sh
bash scripts/build.sh
open build/TokSpeed.app
```

Build a Universal Binary (Apple Silicon + Intel) or run the full test suite:

```sh
UNIVERSAL=1 bash scripts/build.sh
bash scripts/test.sh
```

For Swift tests only, run `swift test`. To render light and dark AppKit previews as part of the full test, pass `--preview-directory PATH` to `scripts/test.sh`.

## Panel & Controls

- **Combined Trend Chart**: Considers up to 60 completed calls per visible tool on a shared speed scale with distinct colors for active tools and minimal Y-axis bounds. Bright lines share a completion-time timeline covering up to six hours before the latest active completion; faint lines show up to six hours before each idle tool’s own last completion. Isolated spikes at least four times faster than both nearby neighbors are omitted from the curve without altering underlying measurements. Hover near any point or over a tool card to inspect speeds, timestamps, models, and highlighted curves.
- **Detailed List**: Switch in **Settings → Panel view** to the classic per-agent list. When an agent has two or more concurrent active or recent sessions, indented sub-rows appear beneath it showing each session's title and speed.
- **Pin, Reorder & Inspect**: Click a card to pin or unpin the menu bar source. Drag cards (or use VoiceOver custom actions) to reorder them. Hover for the measurement basis, median speed and, when recorded, token counts and first-token or first-chunk latency.
- **Settings & Integrations**: Configure **Launch at login**, show/hide installed tools, reset tool order, view local **Diagnostics** (or run `TokSpeed --diagnostics`), and explicitly manage the **Cursor hook** and **Hermes plugin** without silent config edits.

## OpenCode speed

For each completed OpenCode V2 model call, TokSpeed divides output tokens by the time from first token to stream end, excluding both the initial wait and post-stream cleanup. The stream must be within the call's start and completion times, last at least 0.12 s, and yield at most 3,000 tok/s. If stream timing is missing or invalid, or the database uses the V1 schema, TokSpeed uses the call's start-to-completion time instead.

The history and `build/TokSpeed.app/Contents/MacOS/TokSpeed --once --source opencode` use the same per-call calculation. During a turn, speed is total output tokens divided by the sum of those measured durations for completed calls only. It does not count time between calls (such as tool execution) or estimate speed from a partial stream.

## Antigravity speed

TokSpeed reads local Antigravity desktop, `agy` CLI, and T3 Code Antigravity ACP conversation databases. The panel displays the most recently active conversation's speed and updates when Antigravity records usable model-call telemetry for that turn. Until then the menu bar shows elapsed seconds (with `s` even in **Number only** mode). History from another conversation is never used as the active speed. There is no per-token feed: the number only changes when the database provides new measurements.

Like the `antigravity-codex-theme` input indicator, TokSpeed uses output tokens divided by streaming time when the stream lasts at least 0.12 s and the result is greater than 0 and at most 3,000 tok/s. Otherwise it divides by time to first token (TTFT) plus streaming time. The trend only includes completed measurements. `build/TokSpeed.app/Contents/MacOS/TokSpeed --once --source antigravity` reports the measurement basis (including **E2E fallback**), end-to-end rate, total elapsed time and TTFT. The one-second refresh checks database and WAL changes without decoding unchanged files.

## Hermes speed

TokSpeed works without setup using completed calls from Hermes's `logs/agent.log`. Optional: install or update the bundled Hermes user plugin from **Settings → Integrations** or CLI for better timing and in-flight elapsed time on **new** calls:

```sh
TPS=build/TokSpeed.app/Contents/MacOS/TokSpeed
"$TPS" --install-hermes-plugin
hermes plugins enable tokspeed-metrics
# Upgrade an older TokSpeed plugin later:
"$TPS" --install-hermes-plugin --force
# After completing a Hermes reply:
"$TPS" --once --source hermes
```

The installer only copies the plugin files; it does not edit Hermes's configuration or reload a service. Hermes's own `plugins enable` command opts the plugin in and may reload a compatible running gateway. If it doesn't, start a new Hermes process, or reload/restart your gateway when convenient. Disable with `hermes plugins disable tokspeed-metrics` (and optionally remove files via Settings or `--uninstall-hermes-plugin`). Use the same `HERMES_HOME` for installation, Hermes, and TokSpeed (default `~/.hermes`).

For a completed call with reported usage and valid epoch-second timing, TokSpeed divides output tokens by the time from the first chunk to API completion. It accepts spans of at least 0.12 s and rates up to 3,000 tok/s. This is an estimate, not live decoding speed: the first chunk needn't contain visible text, reported output can include reasoning, and API completion can include trailing processing. Non-streaming and unsupported providers or Hermes builds fall back to full API time (hook, or rounded legacy log latency). Missing usage cannot yield a sample. The CLI labels the basis and shows time to first chunk when the estimate is used.

The plugin stores only timing, token counts, model/provider labels, and hashed session/request IDs in bounded local journals under `$HERMES_HOME/plugin-data/tokspeed-metrics/`. Requests with no completion or error expire from the active display after five minutes; TokSpeed does not estimate live token speed for Hermes. The plugin records no prompts, replies, tool arguments, URLs, or credentials and makes no network requests. Hook rows are deduplicated by session/request ID. Legacy log lines are replaced only on an unambiguous nearby match.

## Cursor speed

Cursor remains a whole-turn measurement: recorded output tokens divided by the time from prompt submit to loop stop, including thinking, tools and waiting. Its hook and database don't provide a verified first-chunk timestamp. The menu bar shows elapsed time during a turn.

TokSpeed never modifies `~/.cursor/hooks.json` without explicit user action: enable or remove the hook in **Settings → Integrations** or via `--install-cursor-hook` / `--uninstall-cursor-hook`. The hook invokes the lightweight `tokspeed-cursor-hook` helper binary (no AppKit UI dependencies) and rotates `events.jsonl` at 4 MB to `events.jsonl.1` so recent history is preserved.

## License

[MIT License](LICENSE)
