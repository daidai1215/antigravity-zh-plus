[CmdletBinding()]
param(
    [switch]$Quiet,
    [switch]$CallerHoldsMutex
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$ToolDir = $PSScriptRoot
$ExePath = Join-Path $ToolDir 'antigravity-hans-windows-amd64.exe'
$ConfigPath = Join-Path $ToolDir 'thought-config.json'
$AddonPath = Join-Path $ToolDir 'thought-addon.js'
$OverlayPath = Join-Path $ToolDir 'antigravity-hans-overlay.js'
$OverlayMetaPath = Join-Path $ToolDir 'antigravity-hans-overlay.meta.json'
$StateDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'antigravity-hans-guard'
$BridgeEndpointFile = Join-Path $StateDir 'bridge-endpoint.json'
$LauncherMutexName = 'Local\AntigravityHansLauncherMutex'

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)

function Write-FileAtomically {
    param(
        [string]$TargetPath,
        [string]$Content,
        [System.Text.Encoding]$Encoding
    )
    $dir = [IO.Path]::GetDirectoryName($TargetPath)
    $name = [IO.Path]::GetFileName($TargetPath)
    $rand = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $tmp = Join-Path $dir "$name.tmp.$PID.$rand"
    try {
        [IO.File]::WriteAllText($tmp, $Content, $Encoding)
        if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
            [IO.File]::Replace($tmp, $TargetPath, [NullString]::Value)
        } else {
            try {
                [IO.File]::Move($tmp, $TargetPath)
            } catch [IO.IOException] {
                [IO.File]::Replace($tmp, $TargetPath, [NullString]::Value)
            }
        }
    } finally {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function ConvertTo-StrictBool {
    param($Value, [string]$FieldName)
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        $t = $Value.Trim().ToLowerInvariant()
        if ($t -eq 'true') { return $true }
        if ($t -eq 'false') { return $false }
    }
    throw "thought-config.json 字段 '$FieldName' 必须是布尔值 (true/false)。"
}

function Get-StringSha256Hex {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function New-RandomBridgeToken {
    $bytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::Create()
    try {
        $rng.GetBytes($bytes)
        return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    } finally {
        $rng.Dispose()
    }
}

$Mutex = $null
$HasMutex = $false
if (-not $CallerHoldsMutex) {
    $Mutex = New-Object System.Threading.Mutex($false, $LauncherMutexName)
    try {
        $HasMutex = $Mutex.WaitOne(30000)
    } catch [System.Threading.AbandonedMutexException] {
        $HasMutex = $true
    }
    if (-not $HasMutex) {
        $Mutex.Dispose()
        throw "等待汉化器操作锁超时 (30 秒)，未能执行外部脚本构建。"
    }
}

try {
    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        throw "未找到汉化器主程序: $ExePath"
    }
    if (-not (Test-Path -LiteralPath $AddonPath -PathType Leaf)) {
        throw "未找到思考框翻译扩展脚本: $AddonPath"
    }

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        $initToken = New-RandomBridgeToken
        $defaultCfgObj = [ordered]@{
            enabled      = $true
            provider     = 'auto'
            bridgePort   = 47831
            bridgeToken  = $initToken
            llmApiKey    = ''
            llmBaseUrl   = 'https://open.bigmodel.cn/api/paas/v4/chat/completions'
            llmModel     = 'glm-4-flash'
            geminiApiKey = ''
            geminiModel  = 'gemini-3.5-flash-lite'
        }
        Write-FileAtomically -TargetPath $ConfigPath -Content ($defaultCfgObj | ConvertTo-Json -Depth 4) -Encoding $Utf8NoBom
    }

    $rawCfgText = [IO.File]::ReadAllText($ConfigPath, $Utf8Strict)
    $parsedCfg = $rawCfgText | ConvertFrom-Json
    if ($null -eq $parsedCfg -or ($parsedCfg -is [Array]) -or ($parsedCfg -is [ValueType]) -or ($parsedCfg -is [string])) {
        throw "thought-config.json 根节点必须是 JSON 对象。"
    }

    $normEnabled = if ($null -ne $parsedCfg.PSObject.Properties['enabled'] -and $null -ne $parsedCfg.enabled) {
        ConvertTo-StrictBool -Value $parsedCfg.enabled -FieldName 'enabled'
    } else {
        $true
    }

    $normProvider = if ($null -ne $parsedCfg.PSObject.Properties['provider'] -and $null -ne $parsedCfg.provider) {
        ([string]$parsedCfg.provider).Trim().ToLowerInvariant()
    } else {
        'auto'
    }
    $allowedProviders = @('auto', 'free-direct', 'google-free', 'zhipu', 'openai-compat', 'gemini')
    if ($normProvider -notin $allowedProviders) {
        throw "thought-config.json 字段 'provider' 非法: $normProvider (支持: $($allowedProviders -join ' / '))。"
    }

    $cfgPort = 47831
    if ($null -ne $parsedCfg.PSObject.Properties['bridgePort'] -and $null -ne $parsedCfg.bridgePort) {
        $tmpP = 0
        if ([int]::TryParse([string]$parsedCfg.bridgePort, [ref]$tmpP) -and $tmpP -ge 1024 -and $tmpP -le 65535) {
            $cfgPort = $tmpP
        }
    }

    $cfgToken = if ($null -ne $parsedCfg.PSObject.Properties['bridgeToken'] -and $null -ne $parsedCfg.bridgeToken) {
        ([string]$parsedCfg.bridgeToken).Trim()
    } else {
        ''
    }

    # Ensure persistent bridgeToken exists in thought-config.json so overlay & local-bridge share the exact token
    if ([string]::IsNullOrWhiteSpace($cfgToken) -or $cfgToken.Length -lt 24) {
        $cfgToken = New-RandomBridgeToken
        $updatedMap = [ordered]@{}
        foreach ($prop in $parsedCfg.PSObject.Properties) {
            $updatedMap[$prop.Name] = $prop.Value
        }
        $updatedMap['bridgePort'] = $cfgPort
        $updatedMap['bridgeToken'] = $cfgToken
        Write-FileAtomically -TargetPath $ConfigPath -Content ($updatedMap | ConvertTo-Json -Depth 6) -Encoding $Utf8NoBom
    }

    # If running bridge bound a fallback port, prefer live endpoint port
    $effectiveBridgePort = $cfgPort
    if (Test-Path -LiteralPath $BridgeEndpointFile -PathType Leaf) {
        try {
            $ep = ([IO.File]::ReadAllText($BridgeEndpointFile, [Text.Encoding]::UTF8)) | ConvertFrom-Json
            if ($null -ne $ep -and $null -ne $ep.PSObject.Properties['port']) {
                $liveP = [int]$ep.port
                if ($liveP -ge 1024 -and $liveP -le 65535) {
                    $effectiveBridgePort = $liveP
                }
            }
        } catch {}
    }

    $storedLlmKey = if ($null -ne $parsedCfg.PSObject.Properties['llmApiKey'] -and $null -ne $parsedCfg.llmApiKey) {
        ([string]$parsedCfg.llmApiKey).Trim()
    } else {
        ''
    }
    $normLlmModel = if ($null -ne $parsedCfg.PSObject.Properties['llmModel'] -and $null -ne $parsedCfg.llmModel -and -not [string]::IsNullOrWhiteSpace([string]$parsedCfg.llmModel)) {
        ([string]$parsedCfg.llmModel).Trim()
    } else {
        'glm-4-flash'
    }

    $storedGemKey = if ($null -ne $parsedCfg.PSObject.Properties['geminiApiKey'] -and $null -ne $parsedCfg.geminiApiKey) {
        ([string]$parsedCfg.geminiApiKey).Trim()
    } else {
        ''
    }
    $normGemModel = if ($null -ne $parsedCfg.PSObject.Properties['geminiModel'] -and $null -ne $parsedCfg.geminiModel -and -not [string]::IsNullOrWhiteSpace([string]$parsedCfg.geminiModel)) {
        ([string]$parsedCfg.geminiModel).Trim()
    } else {
        'gemini-3.5-flash-lite'
    }

    # Never embed llmApiKey into JS overlay (local-bridge reads it directly on disk); only embed geminiApiKey when browser direct fallback may need it
    $effectiveGemKey = if ($normEnabled -and $normProvider -in @('auto', 'gemini')) { $storedGemKey } else { '' }
    $effectiveBridgeToken = if ($normEnabled) { $cfgToken } else { '' }
    $hasLlmKeyFlag = ($normEnabled -and (-not [string]::IsNullOrWhiteSpace($storedLlmKey)) -and $normProvider -notin @('free-direct', 'google-free', 'gemini'))

    # 2. Strictly extract unique official embedded overlay.js from antigravity-hans-windows-amd64.exe
    $exeBytes = [IO.File]::ReadAllBytes($ExePath)
    $needleStr = "const LANG_KEY = 'antigravityHansLang';"
    $needleBytes = [Text.Encoding]::UTF8.GetBytes($needleStr)

    $hitOffsets = New-Object 'System.Collections.Generic.List[int]'
    $searchIdx = 0
    $maxIdx = $exeBytes.Length - $needleBytes.Length
    while ($searchIdx -le $maxIdx) {
        $hit = [Array]::IndexOf($exeBytes, $needleBytes[0], $searchIdx)
        if ($hit -lt 0 -or $hit -gt $maxIdx) { break }
        if ($exeBytes[$hit + 10] -eq $needleBytes[10]) {
            $matchAll = $true
            for ($j = 1; $j -lt $needleBytes.Length; $j++) {
                if ($exeBytes[$hit + $j] -ne $needleBytes[$j]) {
                    $matchAll = $false
                    break
                }
            }
            if ($matchAll) {
                $hitOffsets.Add($hit)
            }
        }
        $searchIdx = $hit + 1
    }

    if ($hitOffsets.Count -ne 1) {
        throw "内嵌官方 overlay.js 特征标识匹配数异常 (匹配数: $($hitOffsets.Count)，预期唯一匹配: 1)。"
    }
    $foundOffset = $hitOffsets[0]

    $maxSpan = 4194304
    $startByte = $foundOffset
    while ($startByte -gt 0 -and ($foundOffset - $startByte) -lt $maxSpan) {
        $b = $exeBytes[$startByte - 1]
        if ($b -lt 9 -or ($b -gt 13 -and $b -lt 32)) { break }
        $startByte--
    }

    $endByte = $foundOffset + $needleBytes.Length
    while ($endByte -lt $exeBytes.Length -and ($endByte - $foundOffset) -lt $maxSpan) {
        $b = $exeBytes[$endByte]
        if ($b -lt 9 -or ($b -gt 13 -and $b -lt 32)) { break }
        $endByte++
    }

    $rawSpanJs = $Utf8Strict.GetString($exeBytes, $startByte, $endByte - $startByte)
    $langKeyCharPos = $rawSpanJs.IndexOf($needleStr, [System.StringComparison]::Ordinal)
    if ($langKeyCharPos -lt 0) {
        throw "严格 UTF-8 解码内嵌脚本后未能定位 LANG_KEY。"
    }

    $iifeHeaderLf = "(() => {`n  if (typeof window === 'undefined') return;"
    $iifeStart = $rawSpanJs.LastIndexOf($iifeHeaderLf, $langKeyCharPos, [System.StringComparison]::Ordinal)
    if ($iifeStart -lt 0) {
        $iifeHeaderCrlf = "(() => {`r`n  if (typeof window === 'undefined') return;"
        $iifeStart = $rawSpanJs.LastIndexOf($iifeHeaderCrlf, $langKeyCharPos, [System.StringComparison]::Ordinal)
    }

    $mountMarkerPos = $rawSpanJs.IndexOf('mountToggleUI();', $langKeyCharPos, [System.StringComparison]::Ordinal)
    if ($iifeStart -lt 0 -or $mountMarkerPos -lt 0) {
        throw "内嵌官方 overlay.js 起止锚点校验未通过 (iifeStart=$iifeStart, mountMarker=$mountMarkerPos)。"
    }

    $iifeFooter = '})();'
    $iifeEnd = $rawSpanJs.IndexOf($iifeFooter, $mountMarkerPos, [System.StringComparison]::Ordinal)
    if ($iifeEnd -lt 0) {
        throw "未能在 mountToggleUI() 之后定位闭合 IIFE 边界。"
    }

    $baseOverlayJs = $rawSpanJs.Substring($iifeStart, ($iifeEnd + $iifeFooter.Length) - $iifeStart)
    if ($baseOverlayJs.Length -lt 50000 -or -not $baseOverlayJs.Contains('__antigravityZhPatchInstalled')) {
        throw "提取的官方 overlay.js 长度或核心符号异常 (Length=$($baseOverlayJs.Length))。"
    }

    # 3. Compute deterministic buildId & merge addon
    $addonTemplate = [IO.File]::ReadAllText($AddonPath, $Utf8Strict)
    $placeholder = '/*__AGY_THOUGHT_CONFIG_JSON__*/ {}'
    if (-not $addonTemplate.Contains($placeholder)) {
        throw "thought-addon.js 中缺少配置注入占位符: $placeholder"
    }

    $exeSha = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $addonSha = (Get-FileHash -LiteralPath $AddonPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $cfgSha = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $buildId = (Get-StringSha256Hex -Text "$exeSha|$addonSha|$cfgSha|$effectiveBridgePort").Substring(0, 16)

    $cfgOrdered = [ordered]@{
        enabled      = $normEnabled
        provider     = $normProvider
        bridgePort   = $effectiveBridgePort
        bridgeToken  = $effectiveBridgeToken
        hasLlmKey    = $hasLlmKeyFlag
        llmModel     = $normLlmModel
        geminiApiKey = $effectiveGemKey
        geminiModel  = $normGemModel
        _buildId     = $buildId
    }
    $cfgCompressed = ($cfgOrdered | ConvertTo-Json -Compress).Replace('</', '<\/')
    $configuredAddonJs = $addonTemplate.Replace($placeholder, $cfgCompressed)
    $combinedJs = $baseOverlayJs + "`n`n" + $configuredAddonJs.Trim() + "`n"

    Write-FileAtomically -TargetPath $OverlayPath -Content $combinedJs -Encoding $Utf8NoBom
    $overlaySha = (Get-FileHash -LiteralPath $OverlayPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $metaJson = ([ordered]@{
        buildId    = $buildId
        exeSha     = $exeSha
        addonSha   = $addonSha
        configSha  = $cfgSha
        bridgePort = $effectiveBridgePort
        overlaySha = $overlaySha
        builtUtc   = [DateTime]::UtcNow.ToString('o')
    }) | ConvertTo-Json -Depth 4
    Write-FileAtomically -TargetPath $OverlayMetaPath -Content $metaJson -Encoding $Utf8NoBom

    if (-not $Quiet) {
        $provDesc = if (-not $normEnabled) {
            '已关闭 (仅基础界面汉化)'
        } elseif ($hasLlmKeyFlag) {
            "独立大模型 API ($normProvider / $normLlmModel)"
        } elseif (-not [string]::IsNullOrWhiteSpace($effectiveGemKey)) {
            "官方 Gemini API ($normGemModel)"
        } else {
            "本地免代理直连多段打包 (127.0.0.1:$effectiveBridgePort -> 腾讯 TranSmart)"
        }
        Write-Host "[完成] 已合成外部汉化与思考翻译脚本: antigravity-hans-overlay.js (SHA-256 前缀: $($overlaySha.Substring(0, 16)) | buildId: $buildId | 状态: $provDesc)"
    }
} finally {
    if ($null -ne $Mutex) {
        if ($HasMutex) {
            try { $Mutex.ReleaseMutex() } catch {}
        }
        $Mutex.Dispose()
    }
}
