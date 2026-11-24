<p align="center">
  <img src="../../Resources/AppIcon.png" alt="TokSpeed 圖示" width="120" />
</p>

<h1 align="center">TokSpeed</h1>

<p align="center">
  <strong>在選單列檢查 AI 有沒有偷懶</strong><br>
  輕量 macOS 選單列應用程式，顯示 Codex、OpenCode、Claude Code、Antigravity、Hermes 和 Cursor 的 Token 生成速度。
</p>

<p align="center">
  僅讀取本機日誌——無需 API Key，不上傳、不連網。
</p>

<br>

---

<br>

## 建置、測試與執行

需要 macOS 13+ 和 Xcode Command Line Tools。

```sh
bash scripts/build.sh
open build/TokSpeed.app
```

建置 Apple Silicon + Intel 通用二進位檔案或執行完整測試套件：

```sh
UNIVERSAL=1 bash scripts/build.sh
bash scripts/test.sh
```

## 面板與功能

- **趨勢圖檢視**：以共用速度刻度顯示每個可見工具近期最多 60 次已完成呼叫，活躍工具使用低飽和區分色並顯示極簡縱軸範圍。懸停曲線點或工具卡片可檢視模型、時間與對應高亮曲線。
- **詳細列表檢視**：可在 **設定 → 面板檢視** 切換為經典列表；當某個工具同時有 2 個以上近期或活躍工作階段時，會自動展開縮排子列顯示各自標題與速度。
- **釘選與排序**：點擊卡片即可釘選或取消釘選主要來源；拖曳卡片（或透過旁白動作）即可調整排列順序。
- **設定與整合**：支援**登入時自動啟動**、工具顯示開關、重設順序、本機**診斷資訊**（`TokSpeed --diagnostics`），並可明確安裝、更新或移除 **Cursor Hook** 與 **Hermes 外掛**，絕不靜默改寫使用者設定。

## 各工具測速說明

- **OpenCode**：V2 優先採用首 token 至串流結束耗時（≥ 0.12 秒且 ≤ 3,000 tok/s），否則回退至端到端時間。
- **Antigravity**：讀取 Antigravity Desktop、`agy` CLI 與 T3 Code Antigravity ACP 本機資料庫。
- **Hermes**：預設讀取 `logs/agent.log` 的已完成呼叫。可透過設定或 `--install-hermes-plugin` 安裝本機外掛（以 `--force` 升級），再執行 `hermes plugins enable tokspeed-metrics`，以取得串流速度估算及處理中請求的經過時間。
- **Cursor**：於設定中明確啟用或執行 `--install-cursor-hook` 後，透過輕量無 UI 相依的 `tokspeed-cursor-hook` 紀錄整輪速度，並在 4 MB 時自動輪轉保留 `.1` 歷史紀錄。

## 授權

[MIT License](../../LICENSE)
