<p align="center">
  <img src="../../Resources/AppIcon.png" alt="TokSpeed アイコン" width="120" />
</p>

<h1 align="center">TokSpeed</h1>

<p align="center">
  <strong>AI がサボっていないか、メニューバーでチェック。</strong><br>
  Codex、OpenCode、Claude Code、Antigravity、Hermes、Cursor のトークン生成速度を表示する、軽量な macOS メニューバーアプリ。
</p>

<p align="center">
  ローカルのログのみ読み取ります——API キー不要、アップロードなし、ネットワーク要求なし。
</p>

<br>

---

<br>

## ビルド・テスト・実行

macOS 13+ と Xcode Command Line Tools が必要です。

```sh
bash scripts/build.sh
open build/TokSpeed.app
```

Universal Binary のビルドやテストスイートの実行：

```sh
UNIVERSAL=1 bash scripts/build.sh
bash scripts/test.sh
```

## パネルと機能

- **トレンドグラフ**：表示中の各ツールについて直近最大 60 回の完了呼び出しを共通の速度スケールで描画し、実行中ツールは識別しやすい色分けと最小限の Y 軸目盛りを表示します。ポイントやカードにカーソルを合わせると、対応する曲線と詳細情報が表示されます。
- **詳細リスト**：**設定 → パネル表示** から切り替え可能です。2 つ以上の同時進行または直近のセッションがある場合、各セッションのタイトルと速度がインデントされたサブ行に表示されます。
- **固定と並べ替え**：カードをクリックして監視ソースを固定／解除し、ドラッグ（または VoiceOver アクション）で順序を変更できます。
- **設定と連携**：**ログイン時に自動起動**、ツールの表示切り替え、並び順リセット、ローカル**診断情報**（`TokSpeed --diagnostics`）、および **Cursor フック**・**Hermes プラグイン**の明示的な有効化・更新・削除に対応しています。

## 各ツールの計測仕様

- **OpenCode**：V2 では最初のトークンからストリーム終了まで（0.12 秒以上・3,000 tok/s 以下）を優先し、無効時や V1 では E2E 時間にフォールバックします。
- **Antigravity**：Antigravity Desktop、`agy` CLI、T3 Code Antigravity ACP の各 SQLite データベースを読み取ります。
- **Hermes**：設定不要で `logs/agent.log` の完了済み呼び出しを読み取ります。設定画面または `--install-hermes-plugin`（更新は `--force`）で専用プラグインを導入し、`hermes plugins enable tokspeed-metrics` で有効にすると、ストリーム速度の推定値と進行中のリクエストの経過時間も表示できます。
- **Cursor**：明示的な有効化後に軽量な `tokspeed-cursor-hook` ヘルパーがターン全体の速度を記録し、4 MB 超過時は `.1` へローテーションして履歴を保持します。

## ライセンス

[MIT License](../../LICENSE)
