<p align="center"><img src="Resources/AppIcon.png" alt="TokSpeed アイコン" width="120" /></p>
<h1 align="center">TokSpeed</h1>
<p align="center"><strong>AI がサボっていないか、メニューバーでチェック。</strong></p>
<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="README.zh-TW.md">繁體中文</a> · <strong>日本語</strong> · <a href="README.ko.md">한국어</a> · <a href="README.de.md">Deutsch</a> · <a href="README.fr.md">Français</a> · <a href="README.es.md">Español</a>
</p>

---

TokSpeed は **Codex、OpenCode、Claude Code、Antigravity** のローカル記録からトークン生成速度と最近の呼び出し傾向を表示する、軽量な macOS メニューバーアプリです。API キーも追加のモデル呼び出しも不要です。

## ビルドと実行

**macOS 13 以降**と Swift 5 言語モード対応の Xcode Command Line Tools が必要です。システムの AppKit と SQLite を使用し、外部依存関係はありません。現在の Mac のアーキテクチャ（Apple Silicon または Intel）向けにビルドされ、ユニバーサルバイナリではありません。

必要に応じてコマンドラインツールをインストールし、ダウンロードまたはクローンしたリポジトリ内で実行します。

```sh
xcode-select --install
bash scripts/build.sh
open build/TokSpeed.app
```

アプリはメニューバーにのみ表示され、Dock には表示されません。未インストールのツールは概要、表示元の選択、カスタム順序から非表示になります。インストール済みでも記録がなければ「データなし」と表示します。UI はシステムの優先言語に合わせ、英語、簡体字・繁体字中国語、日本語、韓国語、ドイツ語、フランス語、スペイン語に対応し、未対応言語は英語にフォールバックします。言語変更後は再起動してください。

- **設定…**：macOS ネイティブのウィンドウで変更を即時保存。「終了」はメニューの最後にあります。
- **ソース / 表示**：「自動」または固定ツールを選択。「数値と単位」「数値のみ」「アイコンのみ」に対応。待機中は速度（`tok/s`）ではなく経過秒数（`s`）、待機状態では稲妻のみ表示します。
- **ツールの順序**：ツールを選び ↑ / ↓ で移動。「リセット」で Claude Code → Codex → OpenCode → Antigravity に戻します。実測ユーザー数ではなく、静的な人気順です。
- グラフは隣接サンプルの値を超えない滑らかな曲線です。

`build/TokSpeed.app` をアプリケーションフォルダに移動できます。削除する際はアプリを終了して削除します。表示元・表示モード・順序は UserDefaults に保存され、終了後に `defaults delete io.github.thinkofuture.tokspeed` で消去できます。

現在はソースコードで提供しています。ビルド時の署名はローカルの ad-hoc 署名のみで、Developer ID 署名や Apple の公証はありません。アイコンは `Resources/AppIcon.png` からシステムツールで生成します。

## データソースとプライバシー

| ソース | 既定の場所 |
| --- | --- |
| Codex | `~/.codex/sessions/` と `~/.codex/archived_sessions/` の rollout JSONL。`CODEX_HOME` に対応 |
| OpenCode | `~/.local/share/opencode/opencode.db`。リーダーが実装する V1/V2 テーブル形式に対応 |
| Claude Code | `~/.claude/projects/` の JSONL。サブエージェントを除外。`CLAUDE_CONFIG_DIR` に対応 |
| Antigravity | `~/.gemini/antigravity/conversation_summaries.db` と `conversations/*.db` |

- 全ツールのインストールは不要です。デスクトップアプリと `PATH`・一般的な場所にある実行可能 CLI をローカルで検出し、残存ログだけではインストール済みとしません。検出は自動更新され、固定元が消えた場合は設定を保持したまま自動選択に戻ります。各ソースは前面ウィンドウと無関係に最近の記録を選びます。
- ログには会話内容が含まれる場合があります。統計に必要な項目を解析しますが、アップロード、ネットワーク通信、元ファイルの変更は行いません。SQLite は読み取り専用です。
- 保存するのは表示元・表示モード・順序の設定のみで、会話を複製しません。診断出力のセッション ID やローカルパスは共有前に伏せてください。
- Finder から起動すると通常はターミナルの環境変数を継承しません。独自のデータパスは、変数を設定してアプリ内の実行ファイルをターミナルから直接起動してください。

## 測定と制限

ローカル記録に基づく推定です。**トークンごとの瞬間速度や、厳密なツール間ベンチマークではありません。**

- Codex・OpenCode・Claude Code の今回の速度は、完了した呼び出しの出力トークン合計 ÷ その所要時間の合計です。最初の呼び出しの完了までは秒数だけを表示することがあります。
- 計測範囲はツールごとに異なり、最初のトークンの待ち時間などを含む場合があります。Claude Code はリクエスト開始の記録が必要で、最初の完全な出力ブロックまで計測します。必要な項目がなければデータを表示できません。
- Antigravity は前回の出力トークン数 ÷（最初のトークンの待ち時間 + ストリーミング時間）を完了後に更新します。
- トークン数は各ソースの報告に従い、推論トークンを含む場合があります。グラフは直近最大 12 回の呼び出しで、秒単位のサンプルではなく、縦軸は個別の尺度です。
- 上流の形式は本プロジェクトの管理外です。更新、独自パス、項目不足により欠落や誤差が生じる場合があり、全バージョンの互換性は保証しません。

## 基本チェック

実際の会話を読んだり設定を変更したりせずに、インストール検出・非表示、8 言語とフォールバック、表示モード、順序の保存、曲線、明暗配色、アイコン、Codex の分割書き込みを検証できます。

```sh
build/TokSpeed.app/Contents/MacOS/TokSpeed --test-panel
```

`-AppleLanguages '("ja-JP")'` で言語を指定し、`--preview-directory <ディレクトリ>` で明暗のプレビューを保存できます。

## ライセンス

コードは [MIT License](LICENSE) です。第三者アイコンの出典・ライセンスは [Resources/Logos/NOTICE.md](Resources/Logos/NOTICE.md) に記載し、アプリにも同梱します。ブランド・商標は各所有者に帰属します。本プロジェクトは各ベンダーと提携せず、推奨も受けていません。コードのライセンスは商標権を付与しません。
