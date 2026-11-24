<p align="center">
  <img src="../../Resources/AppIcon.png" alt="TokSpeed-Logo" width="120" />
</p>

<h1 align="center">TokSpeed</h1>

<p align="center">
  <strong>Prüfe in der Menüleiste, ob deine KI trödelt.</strong><br>
  Schlanke macOS-Menüleisten-App, die die Token-Geschwindigkeit von Codex, OpenCode, Claude Code, Antigravity, Hermes und Cursor anzeigt.
</p>

<p align="center">
  Liest nur lokale Logs — kein API-Schlüssel, keine Uploads, keine Netzwerkanfragen.
</p>

<br>

---

<br>

## Bauen, testen und starten

macOS 13+ und Xcode Command Line Tools erforderlich.

```sh
bash scripts/build.sh
open build/TokSpeed.app
```

Universal Binary erstellen oder die komplette Test-Suite ausführen:

```sh
UNIVERSAL=1 bash scripts/build.sh
bash scripts/test.sh
```

## Ansichten & Funktionen

- **Trenddiagramm**: Zeigt bis zu 60 abgeschlossene Aufrufe je sichtbarem Tool auf einer gemeinsamen Geschwindigkeitsskala mit eindeutigen Farben für aktive Tools und minimaler Y-Achsen-Beschriftung. Beim Überfahren eines Punkts oder einer Karte werden Kurve und Details hervorgehoben.
- **Detaillierte Liste**: Unter **Einstellungen → Ansicht** aktivierbar. Bei zwei oder mehr gleichzeitigen oder kürzlichen Sitzungen erscheinen eingerückte Unterzeilen mit Titel und Geschwindigkeit.
- **Anpinnen & Sortieren**: Klicke auf eine Karte, um das Tool als Hauptquelle anzupinnen oder zu lösen; ziehe Karten (oder nutze VoiceOver-Aktionen), um die Reihenfolge zu ändern.
- **Einstellungen & Integrationen**: **Bei Anmeldung starten**, Tools ein-/ausblenden, Reihenfolge zurücksetzen, lokale **Diagnose** (`TokSpeed --diagnostics`) sowie explizite Verwaltung von **Cursor-Hook** (schlanker Helper ohne AppKit, 4-MB-Logrotation) und **Hermes-Plugin** (`--install-hermes-plugin [--force]`).

Für Streaming-Schätzungen und die Laufzeit laufender Hermes-Anfragen das installierte Plugin mit `hermes plugins enable tokspeed-metrics` aktivieren. Ohne Plugin zeigt TokSpeed abgeschlossene Aufrufe aus `logs/agent.log`.

## Lizenz

[MIT License](../../LICENSE)
