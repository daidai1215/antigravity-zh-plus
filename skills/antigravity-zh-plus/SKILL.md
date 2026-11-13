---
name: antigravity-zh-plus
description: >-
  Install, inspect, update, and configure zero-intrusion Chinese UI localization
  and real-time bilingual AI thinking-block translation for Google Antigravity
  on Windows. Activate when the user asks to localize Antigravity into Chinese
  (反重力汉化 / 中文界面 / 自动汉化), translate AI thinking blocks or step labels
  (思考框汉化 / 思维双语翻译 / 中英对照), survive Antigravity auto-updates, switch
  between free Google Translate and official Gemini API translation, or manage
  Antigravity-Hans background guard.
---

# Antigravity Chinese Localization & Bilingual Thinking Plus (`antigravity-zh-plus`)

## Overview

Deploys and manages a dynamic Chinese localization + real-time bilingual thinking-block translator for Google Antigravity on Windows 10/11 (x64):

- **No `app.asar` Modification & Auto-Update Re-Attach**: Never modifies Antigravity's installation files. A lightweight background watcher (`WatchGuard`) monitors real UI processes and re-attaches via local CDP within ~3 seconds whenever Antigravity restarts after an official update.
- **Orphan-Process Safe Launcher**: Distinguishes real Antigravity UI processes from background MCP/plugin subprocesses (`--type=`, `--import`).
- **Action Labels + Bilingual Thinking Translation (`中英对照`)**: Translates step labels (`Thought for Xs` -> `已思考 X 秒`, `Worked for Xm` -> `已工作 X 分`, `Edited` -> `已编辑`, `Analyzed` -> `已分析`, etc.) locally in the DOM, and appends Chinese translations underneath English paragraphs inside expanded/streaming thinking blocks while masking inline `<code>` spans, `$variables`, CLI flags, and file paths.
- **No Internal Session Reuse**: Uses anonymous `translate.googleapis.com` (`POST`, `credentials: 'omit'`) by default, or an optional user-provided Google AI Studio `GEMINI_API_KEY` calling official `gemini-3.5-flash-lite` (`POST /v1beta/interactions`, `store: false`). Never reads or reuses Antigravity's internal OAuth or LanguageServer tokens.

## Privacy, Credentials & Safety

- **External Translation Traffic**: When thinking translation is enabled (`thoughtConfig.enabled = true`), visible English paragraphs inside expanded/streaming thinking blocks (with inline `<code>` and identifier tokens masked to placeholders) are sent over HTTPS to `translate.googleapis.com` (`google-free` / `auto` without key) or `generativelanguage.googleapis.com` (`gemini` / `auto` with key). Disable thinking translation (`-Command set-provider -ThoughtEnabled false`) if strictly offline/no-egress operation is required.
- **API Key Storage**: Interactive `SecureString` input hides terminal keystrokes, and the configured `GEMINI_API_KEY` is stored in `%USERPROFILE%\Tools\Antigravity-Hans\thought-config.json` under the current Windows user profile so [build-overlay.ps1](./scripts/runtime/build-overlay.ps1) can embed runtime configuration locally. Never commit `thought-config.json` or `antigravity-hans-overlay.js`.
- **Ownership-Verified Uninstall**: **Before running `uninstall`**, always obtain explicit user confirmation (refer to `accidental-data-loss-prevention` if installed). [manage-zh-plus.ps1](./scripts/manage-zh-plus.ps1) checks `.antigravity-zh-plus-owned.json`, verifies shortcut targets, removes only known runtime files, and leaves non-empty user directories intact.

## Dependencies

- Windows 10/11 (x64) with Windows PowerShell 5.1.
- Outbound HTTPS access to `api.github.com` / `github.com` (for verified `yuexps/Antigravity-Hans` release download with `SHA256SUMS` verification) and `translate.googleapis.com` (or `generativelanguage.googleapis.com`).

## Quick Start

Run the bundled CLI helper [manage-zh-plus.ps1](./scripts/manage-zh-plus.ps1) and write structured JSON output to a scratch file:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill_dir>/scripts/manage-zh-plus.ps1" -Command install -OutputFile "<scratch_dir>/zh-plus-result.json"
```

Then read `<scratch_dir>/zh-plus-result.json` to verify `installed: true`, `overlayBuilt: true`, `thoughtConfig.configValid: true`, and `statusOutput`.

## Utility Scripts

All operations go through [manage-zh-plus.ps1](./scripts/manage-zh-plus.ps1):

| Subcommand (`-Command`) | Purpose | Example Arguments |
| :--- | :--- | :--- |
| `install` | Deploys runtime to `~\Tools\Antigravity-Hans`, downloads latest `Antigravity-Hans` release with `SHA256SUMS` verification, builds thinking overlay, creates shortcuts, enables startup guard, and hot-attaches live. | `-Command install -OutputFile <path>` |
| `status` | Returns JSON status of Antigravity process, CDP port, attached monitor PID, startup guard, and active translation provider. | `-Command status -OutputFile <path>` |
| `update` | Refreshes runtime scripts, checks/downloads newer upstream `Antigravity-Hans` release, rebuilds external overlay, and hot-reloads live window. | `-Command update [-ForceUpdate] -OutputFile <path>` |
| `set-provider` | Switches thinking translation provider (`google-free`, `gemini`, `auto`) or toggles thinking translation (`-ThoughtEnabled true\|false`) and hot-reloads immediately. | `-Command set-provider -Provider google-free -OutputFile <path>` |
| `rebuild` | Re-extracts official embedded `overlay.js`, merges `thought-addon.js`, and hot-reloads without restarting Antigravity. | `-Command rebuild -OutputFile <path>` |
| `enable-guard` / `disable-guard` | Enables or disables login startup guard and current `WatchGuard` + `antigravity-hans` processes. | `-Command disable-guard -OutputFile <path>` |
| `uninstall` | Stops monitors, unregisters startup guard, removes owned shortcuts and known runtime files in `~\Tools\Antigravity-Hans`. Ask user confirmation first. | `-Command uninstall -OutputFile <path>` |

### Passing an Official `GEMINI_API_KEY` Safely

Never pass plaintext API keys directly in command-line arguments. Either:
1. Instruct the user to double-click `~\Tools\Antigravity-Hans\管理自动汉化守护.cmd` -> `[4]` -> `[2]` (uses hidden `SecureString` prompt), OR
2. Read from an existing environment variable name via `-GeminiApiKeyEnv GEMINI_API_KEY`:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<skill_dir>/scripts/manage-zh-plus.ps1" -Command set-provider -Provider gemini -GeminiApiKeyEnv GEMINI_API_KEY -OutputFile "<scratch_dir>/zh-provider.json"
   ```

## Rate Limiting

- Translation requests in [thought-addon.js](./scripts/runtime/thought-addon.js) enforce `MAX_CONCURRENCY = 2`, a bounded queue (`64` items with subscriber liveness pruning), `480ms` streaming debounce (`1400ms` maxWait), and a `320`-entry `sessionStorage` LRU cache so paragraphs are never re-translated redundantly.
- Full-lifecycle `AbortController` timeouts (`14s` Google Translate / `18s` Gemini API) prevent hung sockets from stalling concurrency slots.

## Common Mistakes

- **Never kill `Antigravity.exe`**: Hot-reload works live via `--attach-only --nogui --trust-external-overlay`. Never close or restart the user's active Antigravity window.
- **Never edit `app.asar`**: Static patching breaks signature/update flows and gets wiped on every client update.
- **PowerShell 5.1 Encoding**: `manage-zh-plus.ps1` automatically writes deployed `.ps1` files with UTF-8 BOM. If manually editing files in `~\Tools\Antigravity-Hans\`, preserve UTF-8 with BOM on `.ps1` files.
