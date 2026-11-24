<p align="center">
  <img src="../../Resources/AppIcon.png" alt="TokSpeed 图标" width="120" />
</p>

<h1 align="center">TokSpeed</h1>

<p align="center">
  <strong>在菜单栏检查 AI 有没有偷懒</strong><br>
  轻量 macOS 菜单栏应用，显示 Codex、OpenCode、Claude Code、Antigravity、Hermes 和 Cursor 的 Token 生成速度。
</p>

<p align="center">
  仅读取本地日志——无需 API Key，不上传、不联网。
</p>

<br>

---

<br>

## 构建、测试与运行

需要 macOS 13+ 和 Xcode Command Line Tools。

```sh
bash scripts/build.sh
open build/TokSpeed.app
```

构建 Apple Silicon + Intel 通用二进制或运行完整测试套件：

```sh
UNIVERSAL=1 bash scripts/build.sh
bash scripts/test.sh
```

## 面板与功能

- **趋势图视图**：以共享速度刻度显示每个可见工具近期最多 60 次已完成调用，活跃工具使用高辨识度低饱和区分色并带极简纵轴范围。亮线共享最近 6 小时时间轴，淡线各自展示闲置工具的近期历史；自动过滤孤立极值尖峰（不修改原始记录）。悬停曲线点或工具卡片可查看模型、状态、时间戳与高亮对应曲线。
- **详情列表视图**：在 **设置 → 面板视图** 切换为经典列表；当某工具存在 2 个及以上并发活跃/近期会话时，下方会展开缩进子行展示各自标题与速度。
- **固定与排序**：点击卡片即可固定或取消固定当前主监控源；拖拽卡片（或使用旁白自定义操作）调整展示顺序。
- **设置与集成管理**：支持**登录时自动启动**、勾选显示/隐藏各工具、重置排序、查看或复制**诊断信息**（也可运行 `TokSpeed --diagnostics`），并在不静默篡改用户配置的前提下显式启用/更新/移除 **Cursor Hook** 与 **Hermes 插件**。

## 各工具测速口径

- **OpenCode**：V2 优先使用「首 token 至流式结束」耗时计算（要求有效流式窗口 ≥ 0.12 秒且速度 ≤ 3,000 tok/s），缺失或 V1 时回退到端到端耗时；本轮速度按已完成调用累加计算，不含工具执行间隙。
- **Antigravity**：同时支持 Antigravity Desktop、`agy` CLI 及 T3 Code Antigravity ACP 数据库，流式耗时有效时取流式速度，否则回退至 `TTFT + stream` 端到端速度。
- **Hermes**：默认读取 `logs/agent.log` 的已完成调用。可在设置中或通过 `--install-hermes-plugin` 安装插件（旧版可加 `--force` 升级），再运行 `hermes plugins enable tokspeed-metrics` 启用，以获取流式速度估算和进行中请求的已耗时。不自动修改 `config.yaml`；缺少结束事件的请求会在五分钟后退出活跃状态。
- **Cursor**：在设置中显式开启或在 CLI 执行 `--install-cursor-hook` 后，使用无 AppKit 依赖的轻量 `tokspeed-cursor-hook` 助手记录整轮起止时间与输出 token（含思考/工具等待时间），日志满 4 MB 自动轮转为 `.1` 保留历史。

## 许可证

[MIT License](../../LICENSE)
