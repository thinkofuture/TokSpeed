<p align="center"><img src="../../Resources/AppIcon.png" alt="TokSpeed-Logo" width="120" /></p>
<h1 align="center">TokSpeed</h1>
<p align="center"><strong>Prüfe in der Menüleiste, ob deine KI trödelt.</strong></p>
<p align="center">
  <a href="../../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <strong>Deutsch</strong> · <a href="README.fr.md">Français</a> · <a href="README.es.md">Español</a>
</p>

---

TokSpeed ist eine schlanke macOS-Menüleisten-App, die lokale Aufzeichnungen von **Codex, OpenCode, Claude Code und Antigravity** liest und die Token-Geschwindigkeit sowie den Verlauf der letzten Aufrufe anzeigt. Kein API-Schlüssel und keine zusätzlichen Modellaufrufe nötig.

## Bauen und starten

Benötigt **macOS 13 oder neuer** und Xcode Command Line Tools mit Swift-5-Sprachmodus. Die App nutzt AppKit und SQLite des Systems, ohne externe Abhängigkeiten. Der Build ist für die Architektur deines Macs (Apple Silicon oder Intel), keine Universal-Binärdatei.

Installiere bei Bedarf die Kommandozeilenwerkzeuge und führe danach im heruntergeladenen oder geklonten Repository aus:

```sh
xcode-select --install
bash scripts/build.sh
open build/TokSpeed.app
```

Die App erscheint nur in der Menüleiste, nicht im Dock. Nicht installierte Tools werden aus Übersicht, Quellenauswahl und eigener Reihenfolge ausgeblendet. Installierte Tools ohne Aufzeichnungen zeigen „Keine Daten“. Die Oberfläche folgt der bevorzugten Systemsprache: Englisch, vereinfachtes/traditionelles Chinesisch, Japanisch, Koreanisch, Deutsch, Französisch oder Spanisch, mit Englisch als Rückfall. Nach einer Sprachänderung die App neu starten.

- **Einstellungen…** öffnet ein natives macOS-Fenster. Änderungen werden sofort gespeichert. „Beenden“ bleibt am Menüende.
- **Quelle / Anzeige**: „Automatisch“ oder festes Tool; „Zahl und Einheit“, „Nur Zahl“ oder „Nur Symbol“. Beim Warten erscheinen Sekunden (`s`) statt Geschwindigkeit (`tok/s`), im Leerlauf nur der Blitz.
- **Tool-Reihenfolge**: Karten direkt im geöffneten Panel ziehen. Eine Einfügelinie zeigt die Position; Loslassen speichert. Außerhalb der Karten ablegen oder Escape drücken, um abzubrechen. Standard: Claude Code → Codex → OpenCode → Antigravity. Die automatische Quellenauswahl bleibt unverändert; VoiceOver bietet Aktionen zum Verschieben nach oben/unten.
- Glatte Verlaufskurven überschreiten nicht den Wertebereich benachbarter Messpunkte.

Du kannst `build/TokSpeed.app` in den Programme-Ordner ziehen. Zum Deinstallieren die App beenden und löschen. Quelle, Anzeige und Reihenfolge werden in UserDefaults gespeichert und lassen sich nach dem Beenden mit `defaults delete io.github.thinkofuture.tokspeed` löschen.

Derzeit wird Quellcode bereitgestellt. Das Build-Skript verwendet nur eine lokale Ad-hoc-Signatur, keine Developer-ID-Signatur oder Apple-Notarisierung. Das App-Symbol wird mit Systemwerkzeugen aus `Resources/AppIcon.png` erzeugt.

## Datenquellen und Datenschutz

| Quelle | Standardpfad |
| --- | --- |
| Codex | Rollout-JSONL in `~/.codex/sessions/` und `~/.codex/archived_sessions/`; berücksichtigt `CODEX_HOME` |
| OpenCode | `~/.local/share/opencode/opencode.db`; die im Reader implementierten V1/V2-Tabellenformate |
| Claude Code | JSONL in `~/.claude/projects/`, ohne Subagent-Aufzeichnungen; berücksichtigt `CLAUDE_CONFIG_DIR` |
| Antigravity | `~/.gemini/antigravity/conversation_summaries.db` und `conversations/*.db` |

- Nicht alle Tools müssen installiert sein. Desktop-Apps und ausführbare CLIs in `PATH` oder üblichen Installationspfaden werden lokal erkannt; alte Logs allein zählen nicht als Installation. Die Erkennung wird automatisch aktualisiert. Fehlt eine festgelegte Quelle, greift vorübergehend die automatische Auswahl, ohne die Einstellung zu löschen. Jede Quelle wählt aktuelle Aufzeichnungen unabhängig vom Vordergrundfenster.
- Logs können Gesprächsinhalte enthalten. TokSpeed verarbeitet die für Statistiken benötigten Felder, lädt aber nichts hoch, startet keine Netzwerkanfragen und verändert keine Quelldateien. SQLite wird schreibgeschützt geöffnet.
- Gespeichert werden nur Quelle, Anzeige und Reihenfolge, keine Gesprächskopien. Diagnoseausgaben können Sitzungs-IDs und lokale Pfade enthalten; vor dem Teilen unkenntlich machen.
- Über Finder gestartete Apps übernehmen gewöhnlich keine Terminal-Umgebungsvariablen. Für eigene Datenpfade Variablen setzen und die ausführbare Datei innerhalb der App direkt im Terminal starten.

## Messung und Grenzen

Die Geschwindigkeit wird aus lokalen Aufzeichnungen geschätzt: **keine momentane Messung pro Token und kein kontrollierter Tool-Vergleich.**

- Für Codex, OpenCode und Claude Code gilt pro Antwort: gesamte Ausgabe-Token abgeschlossener Aufrufe / Summe ihrer aufgezeichneten Laufzeiten. Bis zum ersten Abschluss können nur Sekunden erscheinen.
- Die Zeitgrenzen unterscheiden sich und können die Wartezeit auf das erste Token einschließen. Claude Code benötigt Aufzeichnungen zum Anfragebeginn und misst bis zum ersten vollständigen Ausgabeblock. Fehlende Felder können zu fehlenden Daten führen.
- Antigravity zeigt Ausgabe-Token des letzten Aufrufs / (Wartezeit auf das erste Token + Streaming-Dauer), erst nach Abschluss aktualisiert.
- Token-Zahlen folgen der jeweiligen Quelle und können Reasoning-Token enthalten. Kurven zeigen höchstens 12 letzte Aufrufe, keine Sekundensamples; jede Quelle hat ihre eigene Skala.
- Fremde Datenformate liegen außerhalb unserer Kontrolle. Updates, eigene Pfade oder fehlende Felder können Datenlücken oder Schätzfehler verursachen. Keine umfassende Versionskompatibilität garantiert.

## Grundlegende Prüfungen

Ohne echte Gespräche zu lesen oder App-Einstellungen zu verändern: Installationserkennung und Ausblenden, acht Sprachen mit Rückfall, Anzeigemodi, gespeicherte Reihenfolge, Kurven, helle/dunkle Farben, Symbole und Codex-Teilzeilen prüfen.

```sh
build/TokSpeed.app/Contents/MacOS/TokSpeed --test-panel
```

Mit `-AppleLanguages '("de-DE")'` eine Sprache wählen; mit `--preview-directory <Verzeichnis>` helle/dunkle Vorschauen speichern.

## Lizenz

Der Code steht unter der [MIT License](../../LICENSE). Quellen und Lizenzen fremder Symbole stehen in [Resources/Logos/NOTICE.md](../../Resources/Logos/NOTICE.md) und liegen der App bei. Marken gehören ihren jeweiligen Inhabern. TokSpeed ist weder mit den Anbietern verbunden noch von ihnen empfohlen; die Code-Lizenz gewährt keine Markenrechte.
