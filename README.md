<p align="center">
  <img src="Resources/AppIcon.png" alt="TokSpeed logo" width="120" />
</p>

<h1 align="center">TokSpeed</h1>

<p align="center">
  <strong>Your AI's pace, at a glance.</strong>
</p>

<p align="center">
  <strong>English</strong> · <a href="docs/i18n/README.zh-CN.md">简体中文</a> · <a href="docs/i18n/README.zh-TW.md">繁體中文</a> · <a href="docs/i18n/README.ja.md">日本語</a> · <a href="docs/i18n/README.ko.md">한국어</a> · <a href="docs/i18n/README.de.md">Deutsch</a> · <a href="docs/i18n/README.fr.md">Français</a> · <a href="docs/i18n/README.es.md">Español</a>
</p>

---

TokSpeed is a lightweight macOS menu bar app that reads local records from **Codex, OpenCode, Claude Code, and Antigravity** to show token generation speed and recent call trends. No API key or extra model calls required.

## Build & Run

Requires **macOS 13 or later** and Xcode Command Line Tools with support for Swift 5 language mode. TokSpeed uses the system AppKit and SQLite libraries, with no third-party dependencies to download. The build targets your current Mac's architecture (Apple Silicon or Intel); it is not a universal binary.

Install the command line tools if needed:

```sh
xcode-select --install
```

Download or clone this repository, then run these commands from the repository directory:

```sh
bash scripts/build.sh
open build/TokSpeed.app
```

The app appears only in the menu bar, not in the Dock. Click its icon to see each source, choose the source shown in the menu bar, or quit. Uninstalled tools are hidden from summaries, source choices, and custom ordering. Installed tools without records show a no-data state. The interface automatically follows your system's preferred languages: English, Simplified/Traditional Chinese, Japanese, Korean, German, French, and Spanish, with English as the fallback. Restart the app after changing the system language.

- **Settings…** opens a native macOS window. Changes save immediately. **Quit** stays in the menu, not in Settings.
- **Source / Display**: choose **Automatic** or pin a tool; show **Number and unit**, **Number only**, or **Icon only**. While waiting, numbers are elapsed seconds (`s`), not speed (`tok/s`). Idle always shows a lightning icon.
- **Tool order**: drag tool cards directly in the open panel. An insertion line shows the new position; release to save. Drop outside the cards or press Escape to cancel. The default is Claude Code → Codex → OpenCode → Antigravity. Sorting does not affect automatic source selection; VoiceOver offers Move up / Move down actions.
- Trend charts use smooth curves without overshooting the recorded values.

You can drag `build/TokSpeed.app` to your Applications folder. To uninstall, quit and delete the app. Source, display, and tool-order preferences are stored in macOS UserDefaults; after quitting, you can clear them with `defaults delete io.github.thinkofuture.tokspeed`.

TokSpeed is currently distributed as source code. The build script applies local ad-hoc signing only, without Developer ID signing or Apple notarization. It generates the macOS app icon from the checked-in `Resources/AppIcon.png` using system tools.

## Data Sources & Privacy

| Source | Default location |
| --- | --- |
| Codex | Rollout JSONL files in `~/.codex/sessions/` and `~/.codex/archived_sessions/`; respects `CODEX_HOME` |
| OpenCode | `~/.local/share/opencode/opencode.db`; supports the V1/V2 table layouts implemented in the reader |
| Claude Code | JSONL files in `~/.claude/projects/`, excluding subagent records; respects `CLAUDE_CONFIG_DIR` |
| Antigravity | `~/.gemini/antigravity/conversation_summaries.db` and `conversations/*.db` |

- You do not need to install every supported tool. Desktop apps and executable CLIs on `PATH` or common installation paths are detected locally; leftover logs alone do not count as an installation. Detection refreshes automatically, and a missing pinned source temporarily falls back to automatic selection without erasing your preference. Each installed source selects recent records independently of the foreground window.
- Local logs may contain conversation content. TokSpeed reads those files and parses the fields needed for statistics; it does not upload data, initiate network requests, or modify source logs or databases. SQLite databases are opened read-only.
- TokSpeed saves only source, display, and tool-order preferences, not separate copies of chats. Command line diagnostics may print session IDs and local paths; redact them before sharing output.
- Apps launched from Finder generally do not inherit your terminal's environment variables. For custom directories, set the relevant variables and launch the executable inside the app directly from your terminal.

## Measurements & Limitations

Speeds are estimates based on local records: **not instantaneous per-token measurements, and not a controlled benchmark across tools.**

- For Codex, OpenCode, and Claude Code, the current-turn speed uses completed calls: total output tokens divided by the sum of their recorded durations. While waiting for the first call to finish, the menu bar may show only elapsed seconds.
- Timing boundaries depend on each tool's records and may include time to first token or other overhead. Claude Code requires request-start records and measures up to the first complete output block; missing fields can result in no data.
- Antigravity shows the last call's output tokens divided by time to first token plus streaming duration. It updates only after the call completes.
- Output token counts follow each source's reporting and may include reasoning tokens. Sparklines show up to 12 recent calls, not per-second samples; each source uses its own vertical scale.
- Upstream local formats are not stable interfaces controlled by TokSpeed. Tool updates, custom data paths, or missing fields may cause missing data or inaccurate estimates. Comprehensive compatibility with specific tool versions is not guaranteed.

## Basic Checks

After building, check panel states, light/dark colors, icons, all eight localization tables, language fallback, smooth curves, display modes, menu actions, installation detection/filtering, preference persistence, and the Codex partial-write regression without reading real conversations or changing app preferences:

```sh
build/TokSpeed.app/Contents/MacOS/TokSpeed --test-panel
```

To verify a specific system-language selection, append e.g. `-AppleLanguages '("ja-JP")'`. Add `--preview-directory <directory>` to save light/dark panel previews.

## License

Project code is licensed under the [MIT License](LICENSE). Third-party icon sources and license notices are listed in [Resources/Logos/NOTICE.md](Resources/Logos/NOTICE.md) and bundled with the app. Brands and trademarks belong to their respective owners. TokSpeed is not affiliated with or endorsed by those vendors; the code license does not grant trademark rights.
