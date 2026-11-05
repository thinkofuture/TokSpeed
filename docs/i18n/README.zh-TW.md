<p align="center"><img src="../../Resources/AppIcon.png" alt="TokSpeed 圖示" width="120" /></p>
<h1 align="center">TokSpeed</h1>
<p align="center"><strong>在選單列檢查 AI 有沒有偷懶</strong></p>
<p align="center">
  <a href="../../README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <strong>繁體中文</strong> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.de.md">Deutsch</a> · <a href="README.fr.md">Français</a> · <a href="README.es.md">Español</a>
</p>

---

TokSpeed 是輕量的 macOS 選單列應用程式，讀取 **Codex、OpenCode、Claude Code 和 Antigravity** 的本機紀錄，顯示 Token 生成速度與近期呼叫趨勢。無需 API Key，也不會額外呼叫模型。

## 建置與執行

需要 **macOS 13 或更新版本**與支援 Swift 5 語言模式的 Xcode Command Line Tools。使用系統 AppKit 與 SQLite，沒有第三方相依套件。預設僅建置目前 Mac 的架構（Apple Silicon 或 Intel），不是通用執行檔。

首次安裝命令列工具，然後在下載或複製的儲存庫目錄執行：

```sh
xcode-select --install
bash scripts/build.sh
open build/TokSpeed.app
```

應用程式只出現在選單列，不出現在 Dock。未安裝的工具會從概覽、來源選擇與自訂排序中隱藏；已安裝但沒有紀錄時顯示「暫無資料」。介面自動跟隨系統首選語言，支援英語、簡繁中文、日語、韓語、德語、法語與西班牙語，以英語兜底。變更系統語言後請重新啟動。

- **設定…**：開啟原生 macOS 視窗，變更即時儲存。「結束」獨立放在選單最後。
- **來源 / 顯示**：選擇「自動」或固定工具；支援「數字與單位」「僅數字」「僅圖示」。等待時顯示經過秒數（`s`），不是速度（`tok/s`）；閒置時只顯示閃電。
- **工具排序**：直接在展開面板中拖曳工具卡片，插入線提示目標位置，放開即儲存；拖到卡片區域外或按 Escape 取消。預設順序為 Claude Code → Codex → OpenCode → Antigravity。排序不影響自動來源選擇；VoiceOver 提供「上移 / 下移」操作。
- 趨勢使用平滑曲線，不超出相鄰樣本的數值範圍。

可將 `build/TokSpeed.app` 拖到「應用程式」。解除安裝時退出並刪除應用程式；來源、顯示與排序偏好存於 UserDefaults，退出後可用 `defaults delete io.github.thinkofuture.tokspeed` 清除。

目前以原始碼提供，僅使用本機 ad-hoc 簽署，沒有 Developer ID 簽署或 Apple 公證。建置時使用系統工具從 `Resources/AppIcon.png` 產生圖示。

## 資料來源與隱私

| 來源 | 預設位置 |
| --- | --- |
| Codex | `~/.codex/sessions/` 與 `~/.codex/archived_sessions/` 的 rollout JSONL；支援 `CODEX_HOME` |
| OpenCode | `~/.local/share/opencode/opencode.db`；支援讀取器實作的 V1/V2 資料表結構 |
| Claude Code | `~/.claude/projects/` 的 JSONL，排除子代理紀錄；支援 `CLAUDE_CONFIG_DIR` |
| Antigravity | `~/.gemini/antigravity/conversation_summaries.db` 與 `conversations/*.db` |

- 無需安裝所有工具。本機偵測桌面應用程式及 `PATH`、常見安裝路徑中的可執行 CLI；殘留日誌不算已安裝。偵測自動更新；固定來源消失時暫時回到自動選擇，保留原偏好。各來源獨立選取近期紀錄，不依賴前景視窗。
- 本機日誌可能包含對話內容。TokSpeed 只解析統計所需欄位，不上傳資料、不主動連網、不修改來源檔案；SQLite 以唯讀方式開啟。
- 只儲存來源、顯示與排序偏好，不另存對話。命令列診斷可能輸出工作階段 ID 與本機路徑，分享前請遮蔽。
- Finder 啟動的應用程式通常不繼承終端機環境變數。自訂資料目錄時，請設定變數並從終端機直接執行應用程式內的執行檔。

## 測量與限制

速度依本機紀錄估算，**不是逐 token 瞬時測速，也不是嚴格的跨工具效能基準**。

- Codex、OpenCode、Claude Code 的本輪速度＝已完成呼叫的輸出 token 總數 ÷ 這些呼叫的耗時總和。等待首次呼叫完成時可能只顯示秒數。
- 計時範圍依工具而異，可能包含首 token 延遲。Claude Code 需要請求開始紀錄，計時至首個完整輸出區塊；欄位不足時可能沒有資料。
- Antigravity 顯示上次輸出 token ÷（首 token 延遲 + 串流時間），完成後才更新。
- Token 計數依來源回報，可能包含推理 token。趨勢為最近最多 12 次呼叫，非逐秒資料，各來源使用獨立縱軸。
- 上游格式不受本專案控制；工具更新、自訂路徑或缺少欄位可能造成資料缺失或估算偏差，不保證所有工具版本均相容。

## 基本檢查

無需讀取真實對話或變更應用程式偏好，即可驗證安裝偵測與隱藏、八種語言與兜底、顯示模式、排序持久化、曲線、明暗配色、圖示與 Codex 分段寫入：

```sh
build/TokSpeed.app/Contents/MacOS/TokSpeed --test-panel
```

追加 `-AppleLanguages '("zh-TW")'` 可指定測試語言；追加 `--preview-directory <目錄>` 儲存明暗預覽。

## 授權

程式碼採 [MIT License](../../LICENSE)。第三方圖示來源與授權見 [Resources/Logos/NOTICE.md](../../Resources/Logos/NOTICE.md)，並隨應用程式提供。品牌與商標屬於各自擁有者；本專案不代表相關廠商，也未獲其背書。程式碼授權不授予商標權。
