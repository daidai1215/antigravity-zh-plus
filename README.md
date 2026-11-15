# Antigravity 汉化 Plus · 界面全汉化与思考框双语同传 (`antigravity-zh-plus`)

专为 **Google Antigravity（Windows 10/11 x64）** 打造的**三合一（Antigravity 插件 + Agent Skill + 一键 PowerShell 部署脚本）**全自动动态汉化增强包。

在 [yuexps/Antigravity-Hans](https://github.com/yuexps/Antigravity-Hans) 动态汉化引擎的基础上，彻底解决了**客户端自动更新后汉化失效、共享代理出口 IP 触发 `HTTP 429` 限流、MCP/插件残留子进程误判、AI 思考框与步骤标签全英文**四大痛点。

---

## 核心特性

1. **零改包、官方更新不失效**：绝不修改 `app.asar` 安装包。轻量级后台守护（`WatchGuard`）在官方自动升级重启窗口后 **3 秒内自动重新挂载汉化**。
2. **本地免代理直连桥 + 多段打包（彻底根治共享代理 IP `429` 限流）**：
   - 默认自带仅监听本机回环 `127.0.0.1` 的轻量直连桥（`local-bridge.ps1`，严格校验 `Origin` 与 128 位随机鉴权 Token），强制 `UseProxy = false` **绕开海外共享代理出口 IP**，直接通过你自己的**国内家庭宽带独享 IP** 连接腾讯 AI Lab `transmart.qq.com` 神经机器翻译。
   - 同一思考框内的多段英文自动合并为 **1 次批量请求**（请求次数立减 ~75%），免注册、免填任何 Key 即装即稳。
3. **支持一键切换免费/官方独立大模型 API Key（上限更高）**：
   - **智谱清言 `GLM-4-Flash`**：官方长期**完全免费**开放 API，国内直连高并发、最懂技术代码语境；
   - **硅基流动 SiliconFlow / DeepSeek / 百炼**：默认预设硅基流动免费模型 `Qwen/Qwen2.5-7B-Instruct`（¥0），支持任意 OpenAI 兼容接口；
   - **Google AI Studio `GEMINI_API_KEY`**：官方 `gemini-3.5-flash-lite` 直连；
   - 所有大模型模式异常时均自动无感回退至本地免代理直连桥，且全程 **100% 零反代风险**（绝不读取或借用 Antigravity 内部 OAuth / LanguageServer 会话）。
4. **思考框中英对照 + 代码反引号原子保护**：展开思考框（或流式思考中）自动在英文段落下方附上简体中文译文；自动保护 `` `Write-LiveStatus` ``、`` `$onLine` `` 等 `<code>` 胶囊、CLI 参数、文件路径与混合大小写变量名不被翻坏。
5. **精准防孤儿进程误判**：智能区分真正的 Antigravity 主窗口与后台残留插件/语言服务进程（`--type=`、`--import`），点击桌面 `Antigravity 中文` 图标永不“空转”。

---

## 三种安装方式（任选其一）

### 方式一：一行 PowerShell 全自动安装（最省心，无需 Git）

在任意 Windows 10/11 电脑打开 PowerShell 执行以下命令（自动拉取最新上游 `Antigravity-Hans` 二进制并核验官方 `SHA256SUMS`、启动本地防 `429` 直连桥与后台守护、热注入当前窗口，并同步装好 Antigravity 插件）：

```powershell
irm https://raw.githubusercontent.com/daidai1215/antigravity-zh-plus/main/install.ps1 | iex
```

### 方式二：作为 Antigravity 插件安装

```powershell
git clone https://github.com/daidai1215/antigravity-zh-plus.git
agy plugin install .\antigravity-zh-plus
```

装好后在 Antigravity 对话框直接对 AI 说：
> **“一键安装并开启 Antigravity 全自动中文汉化与思考框双语翻译”**

### 方式三：仅作为独立 Skill 使用（兼容 Antigravity / Codex / Claude Code）

将仓库内的 `skills/antigravity-zh-plus` 复制到对应 Agent 的 `skills` 目录即可：
- **Antigravity**：`~/.gemini/config/skills/antigravity-zh-plus`
- **Codex**：`~/.agents/skills/antigravity-zh-plus`
- **Claude Code**：`~/.claude/skills/antigravity-zh-plus`

---

## 日常管理与切换大模型 API 翻译源

安装后会在 `%USERPROFILE%\Tools\Antigravity-Hans\` 生成两个快捷批处理工具：

- **`管理自动汉化守护.cmd`**：
  - `[1]` 立即挂载汉化并开启开机自动守护 + 本地免代理直连桥
  - `[2]` 停止当前汉化监视器、本地直连桥并关闭自动守护
  - `[3]` 修复桌面与开始菜单 `Antigravity 中文` 快捷方式
  - `[4]` **配置思考框实时翻译源**：
    - `[1]` 免 Key 本地免代理直连 + 多段打包（默认推荐，防代理 429）
    - `[2]` 配置智谱清言官方免费大模型 `GLM-4-Flash` API Key
    - `[3]` 配置硅基流动 SiliconFlow（免费 `Qwen2.5-7B`）/ DeepSeek / 自定义 OpenAI 兼容接口
    - `[4]` 配置 Google AI Studio 独立 `GEMINI_API_KEY`（`gemini-3.5-flash-lite`）
    - `[5]` 关闭思考框实时翻译（仅保留基础界面汉化）
- **`一键更新汉化器.cmd`**：自动检测并升级上游 `Antigravity-Hans` 最新版本（含 SHA-256 强校验），升级后自动重新合成思考框双语覆盖层，无需重配。

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
                ├── local-bridge.ps1                # 本机 127.0.0.1 免代理直连与多段打包桥
                ├── update-hans.ps1
                ├── build-overlay.ps1
                ├── thought-addon.js
                └── thought-config.default.json
```

## 隐私与安全说明

- **回环鉴权隔离**：`local-bridge.ps1` 仅绑定 `127.0.0.1` 回环地址，同时校验本地 `Origin` 白名单与 128 位随机 `bridgeToken`，外部网页无法跨域调用；国内大模型 `llmApiKey` 仅保存在本机 `thought-config.json` 由桥接进程直读，绝不注入前端网页脚本。
- **翻译外发说明**：启用思考框翻译时，展开/流式思考框中的英文段落（代码反引号与标识符已在本地打码替换为占位符）会通过 HTTPS 发送至腾讯交互翻译 `transmart.qq.com` 或你所配置的独立大模型接口；无需外发时可随时切换关闭思考框翻译。
- **零二进制托管**：本仓库仅包含透明可读的源码脚本，运行时二进制由安装脚本直接从上游官方 Release 拉取并强制核对 `SHA256SUMS`。

## 致谢与开源协议

- 基础界面动态汉化二进制由上游开源项目 [yuexps/Antigravity-Hans](https://github.com/yuexps/Antigravity-Hans) 提供。
- 本仓库脚本与扩展代码基于 [MIT License](./LICENSE) 开源。
