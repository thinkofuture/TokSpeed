<p align="center">
  <img src="Resources/AppIcon.png" alt="TokSpeed 图标" width="120" />
</p>

<h1 align="center">TokSpeed</h1>

<p align="center">
  <strong>在菜单栏检查 AI 有没有偷懒</strong>
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong> · <a href="README.zh-TW.md">繁體中文</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.de.md">Deutsch</a> · <a href="README.fr.md">Français</a> · <a href="README.es.md">Español</a>
</p>

---

TokSpeed 是一个轻量的 macOS 菜单栏应用，读取 **Codex、OpenCode、Claude Code 和 Antigravity** 的本地记录，显示 Token 生成速度和最近调用趋势。无需 API Key，不会额外调用模型。

## 构建与运行

要求 **macOS 13 或更新版本**，以及支持 Swift 5 语言模式的 Xcode Command Line Tools。构建使用系统 AppKit 和 SQLite，无需下载第三方依赖。默认仅构建当前 Mac 的架构（Apple Silicon 或 Intel），不是通用二进制。

首次安装编译工具：

```sh
xcode-select --install
```

下载或克隆本仓库，在仓库目录运行：

```sh
bash scripts/build.sh
open build/TokSpeed.app
```

应用仅显示在菜单栏，不显示 Dock 图标。点击图标查看各来源数据、切换菜单栏显示来源或退出。未安装的工具不会出现在概览、来源选择和自定义排序中；已安装但没有记录的工具显示“暂无数据”。界面自动匹配系统首选语言，支持英语、简繁中文、日语、韩语、德语、法语和西班牙语，未支持的语言以英语兜底。修改系统语言后请重新启动应用。

- **设置…**：打开原生 macOS 窗口，修改即时保存。**退出**独立放在菜单最后。
- **来源 / 显示**：选择“自动”或固定工具；支持“数字与单位”“仅数字”“仅图标”。等待时数字表示经过秒数（`s`），非速度（`tok/s`）；空闲时只显示闪电。
- **工具排序**：直接在展开面板中拖动工具卡片，插入线提示目标位置，松手即保存；拖到卡片区域外或按 Escape 取消。默认顺序为 Claude Code → Codex → OpenCode → Antigravity。排序不影响自动来源选择；VoiceOver 提供“上移 / 下移”操作。
- 趋势图使用平滑曲线，不超出相邻样本的数值范围。

可将 `build/TokSpeed.app` 拖到“应用程序”文件夹，退出后删除应用即可卸载。来源、显示模式和工具排序偏好保存在 macOS UserDefaults；退出后可用 `defaults delete io.github.thinkofuture.tokspeed` 清除。

当前以源码方式提供。构建脚本只做本机 ad-hoc 签名，不包含 Developer ID 签名或 Apple 公证；使用系统工具从仓库中的 `Resources/AppIcon.png` 生成 macOS 应用图标。

## 数据来源与隐私

| 来源 | 默认读取位置 |
| --- | --- |
| Codex | `~/.codex/sessions/` 和 `~/.codex/archived_sessions/` 中的 rollout JSONL；支持 `CODEX_HOME` |
| OpenCode | `~/.local/share/opencode/opencode.db`，兼容代码中实现的 V1/V2 表结构 |
| Claude Code | `~/.claude/projects/` 中的 JSONL，跳过子代理记录；支持 `CLAUDE_CONFIG_DIR` |
| Antigravity | `~/.gemini/antigravity/conversation_summaries.db` 和 `conversations/*.db` |

- 不要求同时安装所有工具。本地检测桌面应用，以及 `PATH` 和常见安装目录中的可执行 CLI；仅残留日志不算已安装。检测会自动刷新，固定来源暂时不可用时自动回退，但保留原偏好。各已安装来源自动选取最近记录，不绑定当前前台窗口。
- 本地日志可能含有对话内容；应用会读取日志文件并解析统计需要的字段，不上传数据，不主动发起网络请求，也不修改源日志或数据库。SQLite 以只读模式打开。
- 应用只保存来源、显示模式和工具排序偏好，不另存聊天记录。命令行诊断可能输出会话 ID 和本地路径，分享输出前请脱敏。
- 从 Finder 启动通常不会继承终端环境变量；使用自定义目录时，可从终端直接运行应用中的可执行文件并设置相应变量。

## 速度统计与限制

速度基于本地记录估算，**不是逐 token 瞬时测速，也不是严格的跨工具性能基准**。

- Codex、OpenCode、Claude Code 的“本轮”速度来自已完成调用：输出 token 总数 ÷ 这些调用的记录耗时之和；等待首个调用完成时可能只显示经过秒数。
- 耗时取决于各工具记录的时间边界，可能包含首 token 延迟等开销。Claude Code 依赖请求开始记录，并按首个完整输出块计时；缺少这些字段时可能没有数据。
- Antigravity 显示上次调用的输出 token ÷（首 token 延迟 + 流式时长），完成后才更新。
- 输出 token 按各来源报告的口径统计，可能包含推理 token；趋势图是最近最多 12 次调用，非逐秒数据，各来源使用独立纵轴。
- 这些工具的本地格式不是本项目控制的稳定接口；上游更新、自定义数据路径或缺少字段可能导致无数据或估算偏差。目前不承诺具体工具版本的全面兼容。

## 基本检查

构建后可检查面板状态、明暗配色、图标、八种语言翻译与兜底、平滑曲线、显示模式、菜单操作、安装检测与过滤、偏好持久化及 Codex 分段写入回归用例，无需读取真实会话或修改应用偏好：

```sh
build/TokSpeed.app/Contents/MacOS/TokSpeed --test-panel
```

可追加 `-AppleLanguages '("ja-JP")'` 验证特定系统语言；追加 `--preview-directory <目录>` 保存明暗面板预览图。

## 许可证

项目代码采用 [MIT License](LICENSE)。第三方图标来源及授权见 [Resources/Logos/NOTICE.md](Resources/Logos/NOTICE.md)，构建时随应用打包。品牌和商标归各自所有者所有，项目不代表相关厂商，也未获其背书；代码许可证不授予商标权。
