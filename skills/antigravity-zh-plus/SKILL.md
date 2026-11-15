---
name: antigravity-zh-plus
description: >-
  Install, inspect, update, and configure zero-intrusion Chinese UI localization
  and real-time bilingual AI thinking-block translation for Google Antigravity
  on Windows. Activate when the user asks to localize Antigravity into Chinese
  (反重力汉化 / 中文界面 / 自动汉化), translate AI thinking blocks or step labels
  (思考框汉化 / 思维双语翻译 / 中英对照), survive Antigravity auto-updates, bypass
  shared proxy HTTP 429 rate limits, configure Zhipu GLM-4-Flash / SiliconFlow /
  DeepSeek / Gemini API translation, or manage Antigravity-Hans background guard.
---

# Antigravity Chinese Localization & Bilingual Thinking Plus (`antigravity-zh-plus`)

## Overview

Deploys and manages a dynamic Chinese localization + real-time bilingual thinking-block translator for Google Antigravity on Windows 10/11 (x64):

- **No `app.asar` Modification & Auto-Update Re-Attach**: Never modifies Antigravity's installation files. `WatchGuard` monitors real UI processes and re-attaches via local CDP within ~3 seconds whenever Antigravity restarts after an official update.
- **Zero-Key Local Direct Bridge + Multi-Paragraph Batching (Anti-429)**: Runs a lightweight loopback-only bridge ([local-bridge.ps1](./scripts/runtime/local-bridge.ps1), `127.0.0.1:47831`, protected by Origin check + 128-bit `bridgeToken`) with `UseProxy = false` so zero-key requests bypass shared foreign proxy exit IPs (`HTTP 429`) and connect directly via the user's residential broadband IP to Tencent AI Lab `transmart.qq.com/api/imt`, batching up to 8 paragraphs per thinking block into a single HTTP request (~75% fewer calls).
- **Optional Account-Level Free/Official LLM APIs & Local Offline Models**: Supports one-command or interactive configuration of **Zhipu official free `glm-4-flash`** (`zhipu`), **SiliconFlow free `Qwen/Qwen2.5-7B-Instruct` / DeepSeek / custom OpenAI-compatible APIs** (`openai-compat`), **Google AI Studio `gemini-3.5-flash-lite`** (`gemini`), or **local offline `Ollama` models** (`local-llm`, e.g. `qwen2.5:3b` on `http://127.0.0.1:11434/v1/chat/completions`), with automatic fallback to the local direct bridge.
- **Inline Rate-Limit & Failure Guidance**: If all translation channels encounter concurrent rate limiting or network failure, renders a non-intrusive inline tip bar inside the thinking block with a one-click `[立即重试]` button and clear instructions to connect a free personal API key, deploy a local Ollama model, or update the skill/plugin.
- **No Internal Session Reuse**: Never reads or reuses Antigravity's internal OAuth or LanguageServer tokens.

## Privacy, Credentials & Safety

- **External Translation Traffic**: When thinking translation is enabled (`thoughtConfig.enabled = true`), visible English paragraphs inside expanded/streaming thinking blocks (with inline `<code>` and identifier tokens masked to placeholders) are sent over HTTPS to `transmart.qq.com` via the local direct bridge (falling back to `translate.googleapis.com` / `api.mymemory.translated.net` if the local bridge is unavailable), or to the user's configured LLM endpoint (`open.bigmodel.cn`, `api.siliconflow.cn`, `generativelanguage.googleapis.com`, etc.). Disable thinking translation (`-Command set-provider -ThoughtEnabled false`) if strictly offline/no-egress operation is required.
- **API Key Storage**: Interactive `SecureString` input hides terminal keystrokes. Configured keys (`llmApiKey`, `geminiApiKey`) and the per-install random `bridgeToken` are stored in `%USERPROFILE%\Tools\Antigravity-Hans\thought-config.json` under the current Windows user profile (`llmApiKey` is read directly on disk by `local-bridge.ps1` and never embedded into `antigravity-hans-overlay.js`). Never commit `thought-config.json` or `antigravity-hans-overlay.js`.
- **Ownership-Verified Uninstall**: **Before running `uninstall`**, always obtain explicit user confirmation (refer to `accidental-data-loss-prevention` if installed). [manage-zh-plus.ps1](./scripts/manage-zh-plus.ps1) checks `.antigravity-zh-plus-owned.json`, verifies shortcut targets, stops `WatchGuard` + `local-bridge.ps1`, removes only known runtime files, and leaves non-empty user directories intact.

## Dependencies

- Windows 10/11 (x64) with Windows PowerShell 5.1 (.NET Framework 4.8).
- Outbound HTTPS access to `api.github.com` / `github.com` (for verified `yuexps/Antigravity-Hans` release download with `SHA256SUMS` verification) and the active translation endpoint.

## Quick Start

Run the bundled CLI helper [manage-zh-plus.ps1](./scripts/manage-zh-plus.ps1) and write structured JSON output to a scratch file:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill_dir>/scripts/manage-zh-plus.ps1" -Command install -OutputFile "<scratch_dir>/zh-plus-result.json"
```

Then read `<scratch_dir>/zh-plus-result.json` to verify `installed: true`, `overlayBuilt: true`, `thoughtConfig.configValid: true`, and `statusOutput`.

> **Important for AI Agent Shells (`run_command`)**: Non-daemon agent tool calls execute inside a Windows Job Object that terminates child processes when the command exits. After running `install`, `update`, `rebuild`, or `enable-guard` from an agent shell, if `status` shows `后台自动汉化守护 : 未运行`, launch `launch-hans.ps1 -Watch` in a separate `run_command` call with `IsDaemon: true` so `WatchGuard`, `local-bridge.ps1`, and the CDP monitor persist continuously in the background.

## Utility Scripts

All operations go through [manage-zh-plus.ps1](./scripts/manage-zh-plus.ps1):

| Subcommand (`-Command`) | Purpose | Example Arguments |
| :--- | :--- | :--- |
| `install` | Deploys runtime + local bridge to `~\Tools\Antigravity-Hans`, verifies `SHA256SUMS`, builds thinking overlay, creates shortcuts, enables startup guard, and hot-attaches live. | `-Command install -OutputFile <path>` |
| `status` | Returns JSON status of Antigravity process, CDP port, attached monitor PID, `WatchGuard`, local direct bridge (`127.0.0.1:47831`), and active translation provider. | `-Command status -OutputFile <path>` |
| `update` | Refreshes runtime scripts, checks/downloads newer upstream `Antigravity-Hans` release, rebuilds external overlay, and hot-reloads live window. | `-Command update [-ForceUpdate] -OutputFile <path>` |
| `set-provider` | Switches provider (`free-direct`, `zhipu`, `openai-compat`, `gemini`, `auto`) or toggles thinking translation (`-ThoughtEnabled true\|false`) and hot-reloads immediately. | `-Command set-provider -Provider free-direct -OutputFile <path>` |
| `rebuild` | Ensures `local-bridge.ps1` is running, merges `thought-addon.js`, and hot-reloads without restarting Antigravity. | `-Command rebuild -OutputFile <path>` |
| `enable-guard` / `disable-guard` | Enables or disables login startup guard, `local-bridge.ps1`, `WatchGuard`, and `antigravity-hans` processes. | `-Command disable-guard -OutputFile <path>` |
| `uninstall` | Stops monitors & local bridge, unregisters startup guard, removes owned shortcuts and known runtime files in `~\Tools\Antigravity-Hans`. Ask user confirmation first. | `-Command uninstall -OutputFile <path>` |

### Passing an Official LLM API Key Safely

Never pass plaintext API keys directly in command-line arguments. Either:
1. Instruct the user to double-click `~\Tools\Antigravity-Hans\管理自动汉化守护.cmd` -> `[4]` (uses hidden `SecureString` prompt for Zhipu `GLM-4-Flash`, SiliconFlow / DeepSeek, or Google AI Studio `GEMINI_API_KEY`), OR
2. Read from an existing environment variable name:
   ```powershell
   # Zhipu Official Free GLM-4-Flash:
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill_dir>/scripts/manage-zh-plus.ps1" -Command set-provider -Provider zhipu -LlmApiKeyEnv ZHIPU_API_KEY -OutputFile "<scratch_dir>/zh-provider.json"

   # SiliconFlow Free Qwen2.5-7B / DeepSeek / OpenAI-Compatible:
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill_dir>/scripts/manage-zh-plus.ps1" -Command set-provider -Provider openai-compat -LlmBaseUrl "https://api.siliconflow.cn/v1/chat/completions" -LlmModel "Qwen/Qwen2.5-7B-Instruct" -LlmApiKeyEnv SILICONFLOW_API_KEY -OutputFile "<scratch_dir>/zh-provider.json"

   # Google AI Studio Official Gemini:
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill_dir>/scripts/manage-zh-plus.ps1" -Command set-provider -Provider gemini -GeminiApiKeyEnv GEMINI_API_KEY -OutputFile "<scratch_dir>/zh-provider.json"

   # Local Offline Ollama Model (zero API key, zero network):
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill_dir>/scripts/manage-zh-plus.ps1" -Command set-provider -Provider local-llm -LlmBaseUrl "http://127.0.0.1:11434/v1/chat/completions" -LlmModel "qwen2.5:3b" -OutputFile "<scratch_dir>/zh-provider.json"
   ```

### Updating the Skill & Plugin from GitHub

When the user asks to "更新 antigravity-zh-plus / 更新汉化 skill", run the published pure-ASCII installer to pull the latest plugin, skill, and runtime in place:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/daidai1215/antigravity-zh-plus/main/install.ps1 | iex"
```

## Rate Limiting & Concurrency

- [thought-addon.js](./scripts/runtime/thought-addon.js) groups up to `8` uncached paragraphs per thinking block into a single batch request, enforces `MAX_CONCURRENCY = 2`, a bounded queue (`64` items), `480ms` streaming debounce (`1400ms` maxWait), and a `320`-entry `sessionStorage` LRU cache.
- [local-bridge.ps1](./scripts/runtime/local-bridge.ps1) enforces loopback-only binding (`127.0.0.1`), Origin allowlist + constant-time `bridgeToken` verification, `64KB` payload limit, and `SemaphoreSlim(4)` concurrency gating.

## Common Mistakes

- **Never kill `Antigravity.exe`**: Hot-reload works live via `--attach-only --nogui --trust-external-overlay`.
- **Never edit `app.asar`**: Static patching breaks signature/update flows and gets wiped on every client update.
- **PowerShell 5.1 Encoding**: `manage-zh-plus.ps1` automatically writes deployed `.ps1` files with UTF-8 BOM.
