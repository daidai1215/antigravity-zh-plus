# Antigravity 汉化 Plus · 界面全汉化与思考框双语同传 (`antigravity-zh-plus`)

专为 **Google Antigravity（Windows 10/11 x64）** 打造的**三合一（Antigravity 插件 + Agent Skill + 一键 PowerShell 部署脚本）**全自动动态汉化增强包。

在 [yuexps/Antigravity-Hans](https://github.com/yuexps/Antigravity-Hans) 动态汉化引擎的基础上，彻底解决了**客户端自动更新后汉化失效、MCP/插件残留子进程误判、AI 思考框与步骤标签全英文**三大痛点。

---

## 核心特性

1. **零改包、官方更新不失效**：绝不修改 `app.asar` 安装包。轻量级后台守护（`WatchGuard`）在官方自动升级重启窗口后 **3 秒内自动重新挂载汉化**。
2. **精准防孤儿进程误判**：智能区分真正的 Antigravity 主窗口与后台残留插件/语言服务进程（`--type=`、`--import`），点击桌面 `Antigravity 中文` 图标永不“空转”。
3. **对话动作标签即时汉化**：自动将对话流中的 `Thought for 24s`（`已思考 24 秒`）、`Thinking...`（`思考中...`）、`Worked for 2m`（`已工作 2 分`）、`Edited`（`已编辑`）、`Analyzed`（`已分析`）、`Created`、`Ran`、`Read` 等标签汉化，且绝不误伤右侧代码文件名胶囊。
4. **思考框中英对照实时翻译 + 代码反引号保护**：展开思考框（或流式思考中）自动在英文段落下方附上简体中文译文；自动保护 `` `Write-LiveStatus` ``、`` `$onLine` `` 等 `<code>` 胶囊、CLI 参数、文件路径与混合大小写变量名不被翻坏。
5. **100% 零反代风险**：
   - **默认免 Key 即装即用**：匿名直连公开 `translate.googleapis.com`（`POST`，`credentials: 'omit'`），绝不读取或借用 Antigravity 内部 OAuth / LanguageServer 会话。
   - **可选官方 `gemini-3.5-flash-lite`**：支持填入你在 Google AI Studio 独立申请的 `GEMINI_API_KEY`，直连官方 Interactions API（`v1beta/interactions`，`thinking_level: "minimal"`，`store: false`），异常时自动无感降级网页翻译。

---

## 三种安装方式（任选其一）

### 方式一：一行 PowerShell 全自动安装（最省心，无需 Git）

在任意另一台 Windows 电脑打开 PowerShell 执行以下命令（自动拉取最新上游 `Antigravity-Hans` 二进制并核验官方 `SHA256SUMS`、开启后台自动守护、热注入当前窗口，并同步装好 Antigravity 插件）：

```powershell
irm https://raw.githubusercontent.com/daidai1215/antigravity-zh-plus/main/install.ps1 | iex
```

### 方式二：作为 Antigravity 插件安装

克隆仓库并用 `agy` CLI 安装插件：

```powershell
git clone https://github.com/daidai1215/antigravity-zh-plus.git
agy plugin install .\antigravity-zh-plus
```

（或直接克隆到 `"$HOME\.gemini\config\plugins\antigravity-zh-plus"`）

然后在 Antigravity 对话框直接对 AI 说：
> **“一键安装并开启 Antigravity 全自动中文汉化与思考框双语翻译”**

AI 会自动读取内置 Skill 完成全套下载、SHA-256 校验、守护注册与当前窗口无感热注入。

### 方式三：仅作为独立 Skill 使用（兼容 Antigravity / Codex / Claude Code）

只需将仓库内的 `skills/antigravity-zh-plus` 文件夹复制到对应 Agent 的 `skills` 目录即可：
- **Antigravity**：`~/.gemini/config/skills/antigravity-zh-plus`
- **Codex**：`~/.agents/skills/antigravity-zh-plus`
- **Claude Code**：`~/.claude/skills/antigravity-zh-plus`

---

## 日常管理与切换 Gemini API 翻译源

安装后会在 `%USERPROFILE%\Tools\Antigravity-Hans\` 生成两个快捷批处理工具：

- **`管理自动汉化守护.cmd`**：
  - `[1]` 立即挂载汉化并开启开机自动守护
  - `[2]` 停止当前汉化监视器并关闭自动守护
  - `[3]` 修复桌面与开始菜单 `Antigravity 中文` 快捷方式
  - `[4]` **配置思考框实时翻译源**（切换免 Key 网页翻译 / 隐藏回显粘贴独立 `GEMINI_API_KEY` 直连 `gemini-3.5-flash-lite` / 关闭思考翻译）
- **`一键更新汉化器.cmd`**：自动检测并升级上游 `Antigravity-Hans` 最新版本（含 SHA-256 强校验），升级后自动重新提取官方词库并与思考框翻译扩展合成，无需重配。

也可以在对话中直接让 AI 执行：
- *“检查当前 Antigravity 汉化守护状态”*
- *“帮我更新汉化器到最新版”*
- *“暂时关闭反重力自动汉化”*

---

## 目录结构

```text
antigravity-zh-plus/
├── plugin.json                                     # Antigravity 插件清单
├── install.ps1                                     # 一键远程/本地引导安装脚本
├── assets/
│   └── logo.svg                                    # 插件图标
└── skills/
    └── antigravity-zh-plus/
        ├── SKILL.md                                # Agent Skill 规范与指令
        └── scripts/
            ├── manage-zh-plus.ps1                  # Skill 统一 CLI 控制器
            └── runtime/                            # 运行时核心脚本与思考框翻译扩展
                ├── launch-hans.vbs
                ├── launch-hans.ps1
                ├── update-hans.ps1
                ├── build-overlay.ps1
                ├── thought-addon.js
                └── thought-config.default.json
```

## 隐私与安全说明

- **翻译请求**：启用思考框翻译时，展开/流式思考框中的英文段落（代码反引号与标识符已在本地打码替换为占位符）会通过 HTTPS 发送至 `translate.googleapis.com` 或 `generativelanguage.googleapis.com`；无需外发时可随时切换关闭思考框翻译。
- **零二进制托管**：本仓库仅包含透明可读的源码脚本，运行时二进制由安装脚本直接从上游官方 Release 拉取并强制核对 `SHA256SUMS`。

## 致谢与开源协议

- 基础界面动态汉化二进制由上游开源项目 [yuexps/Antigravity-Hans](https://github.com/yuexps/Antigravity-Hans) 提供。
- 本仓库脚本与扩展代码基于 [MIT License](./LICENSE) 开源。
