[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('install', 'status', 'update', 'set-provider', 'rebuild', 'enable-guard', 'disable-guard', 'stop', 'uninstall')]
    [string]$Command = 'status',

    [string]$InstallDir = '',

    [ValidateSet('', 'auto', 'google-free', 'gemini')]
    [string]$Provider = '',

    [ValidateSet('', 'true', 'false')]
    [string]$ThoughtEnabled = '',

    [string]$GeminiModel = '',

    [string]$GeminiApiKeyEnv = '',

    [switch]$ClearGeminiApiKey,

    [switch]$ForceUpdate,

    [switch]$NoStartup,

    [switch]$NoShortcuts,

    [string]$OutputFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Console]::OutputEncoding = [Text.Encoding]::UTF8

function Resolve-NormalizedPath {
    param([string]$InputPath)
    $raw = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InputPath)
    $full = [IO.Path]::GetFullPath($raw)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) {
        $full = $full.TrimEnd('\', '/')
    }
    return $full
}

$DefaultInstallDir = Resolve-NormalizedPath (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Tools\Antigravity-Hans')
if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = $DefaultInstallDir
} else {
    $InstallDir = Resolve-NormalizedPath $InstallDir
}

if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
    $OutputFile = Resolve-NormalizedPath $OutputFile
}

$ScriptRoot = Resolve-NormalizedPath $PSScriptRoot
$RuntimeSrcDir = Join-Path $ScriptRoot 'runtime'
$PowerShellExe = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $PowerShellExe -PathType Leaf)) {
    $PowerShellExe = 'powershell.exe'
}
$WscriptPath = Join-Path ([Environment]::SystemDirectory) 'wscript.exe'

$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Construct friendly Chinese filenames via Unicode codepoints so this script stays 100% 7-bit ASCII
$GuardCmdName = (-join ([char[]]@(0x7BA1, 0x7406, 0x81EA, 0x52A8, 0x6C49, 0x5316, 0x5B88, 0x62A4))) + '.cmd'
$UpdateCmdName = (-join ([char[]]@(0x4E00, 0x952E, 0x66F4, 0x65B0, 0x6C49, 0x5316, 0x5668))) + '.cmd'
$ZhShortcutName = 'Antigravity ' + (-join ([char[]]@(0x4E2D, 0x6587))) + '.lnk'
$OwnershipMarkerName = '.antigravity-zh-plus-owned.json'
$LegacyMarkerName = '.antigravity-zh-guard-owned.json'

$KnownOwnedFiles = @(
    $OwnershipMarkerName,
    $LegacyMarkerName,
    'launch-hans.ps1',
    'launch-hans.vbs',
    'update-hans.ps1',
    'build-overlay.ps1',
    'thought-addon.js',
    'thought-config.json',
    'antigravity-hans-windows-amd64.exe',
    'antigravity-hans-windows-amd64.exe.bak',
    'SHA256SUMS',
    'VERSION.txt',
    'antigravity-hans-overlay.js',
    'antigravity-hans-overlay.meta.json',
    $GuardCmdName,
    $UpdateCmdName
)

function Test-PathHasReparsePoint {
    param([string]$TargetPath)
    $full = Resolve-NormalizedPath $TargetPath
    $root = [IO.Path]::GetPathRoot($full)
    $cur = $full
    while (-not [string]::IsNullOrWhiteSpace($cur)) {
        if (Test-Path -LiteralPath $cur) {
            $item = Get-Item -LiteralPath $cur -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                if ($cur -ne $root) {
                    return $true
                }
            }
        }
        if ($cur -ieq $root -or $cur -ieq $root.TrimEnd('\')) {
            break
        }
        $parent = Split-Path -Parent $cur
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ieq $cur) {
            break
        }
        $cur = $parent
    }
    return $false
}

function Assert-SafeInstallDirectory {
    param([string]$CandidateDir)
    if ([string]::IsNullOrWhiteSpace($CandidateDir)) {
        throw 'InstallDir cannot be empty.'
    }
    if ($CandidateDir.StartsWith('\\')) {
        throw "UNC paths are not supported for InstallDir: $CandidateDir"
    }
    $root = [IO.Path]::GetPathRoot($CandidateDir)
    if ([string]::IsNullOrWhiteSpace($root) -or $CandidateDir.TrimEnd('\') -ieq $root.TrimEnd('\')) {
        throw "Refusing to use drive root as InstallDir: $CandidateDir"
    }

    $protectedDirs = New-Object 'System.Collections.Generic.List[string]'
    foreach ($sf in @('UserProfile', 'Desktop', 'Personal', 'ApplicationData', 'LocalApplicationData', 'CommonApplicationData', 'ProgramFiles', 'ProgramFilesX86', 'Windows', 'System')) {
        $p = [Environment]::GetFolderPath($sf)
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            $protectedDirs.Add((Resolve-NormalizedPath $p))
        }
    }
    $tmpRoot = [IO.Path]::GetTempPath()
    if (-not [string]::IsNullOrWhiteSpace($tmpRoot)) {
        $protectedDirs.Add((Resolve-NormalizedPath $tmpRoot))
    }

    foreach ($prot in $protectedDirs) {
        if ($CandidateDir.Equals($prot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to use protected directory as InstallDir: $CandidateDir"
        }
        $candPrefix = $CandidateDir.TrimEnd('\') + '\'
        if ($prot.StartsWith($candPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to use ancestor of protected directory ($prot) as InstallDir: $CandidateDir"
        }
    }

    $scriptPrefix = $ScriptRoot.TrimEnd('\') + '\'
    $candWithSep = $CandidateDir.TrimEnd('\') + '\'
    if ($CandidateDir.Equals($ScriptRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $CandidateDir.StartsWith($scriptPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        $ScriptRoot.StartsWith($candWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "InstallDir ($CandidateDir) must not overlap skill script directory ($ScriptRoot)."
    }

    if (Test-PathHasReparsePoint -TargetPath $CandidateDir) {
        throw "Refusing to operate on InstallDir containing a symlink, junction, or reparse point: $CandidateDir"
    }
}

function Test-DirectoryOwnedByGuard {
    param([string]$DirPath)
    if (-not (Test-Path -LiteralPath $DirPath -PathType Container)) {
        return $false
    }
    foreach ($mName in @($OwnershipMarkerName, $LegacyMarkerName)) {
        $markerPath = Join-Path $DirPath $mName
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            try {
                $m = ([IO.File]::ReadAllText($markerPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
                if ($null -ne $m -and ($null -ne $m.PSObject.Properties['product']) -and ([string]$m.product -in @('antigravity-zh-plus', 'antigravity-zh-guard'))) {
                    return $true
                }
            } catch {}
        }
    }
    # Legacy recognition for pre-marker Antigravity-Hans installations created by our runtime
    $leaf = Split-Path -Leaf $DirPath
    if ($leaf -ieq 'Antigravity-Hans' -and
        (Test-Path -LiteralPath (Join-Path $DirPath 'launch-hans.ps1') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $DirPath 'thought-addon.js') -PathType Leaf)) {
        return $true
    }
    return $false
}

function Enter-MutexOrThrow {
    param(
        [string]$Name,
        [int]$TimeoutMs = 20000
    )
    $m = New-Object System.Threading.Mutex($false, $Name)
    $acquired = $false
    try {
        try {
            $acquired = $m.WaitOne($TimeoutMs)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            $m.Dispose()
            throw "Timed out waiting for lock '$Name' (${TimeoutMs}ms)."
        }
        return $m
    } catch {
        if (-not $acquired) {
            try { $m.Dispose() } catch {}
        }
        throw
    }
}

function Exit-MutexSafely {
    param([System.Threading.Mutex]$MutexObj)
    if ($null -ne $MutexObj) {
        try { $MutexObj.ReleaseMutex() } catch {}
        try { $MutexObj.Dispose() } catch {}
    }
}

function Write-TextAtomically {
    param(
        [string]$Path,
        [string]$Content,
        [System.Text.Encoding]$Encoding
    )
    $normTarget = Resolve-NormalizedPath $Path
    if (Test-PathHasReparsePoint -TargetPath $normTarget) {
        throw "Refusing to write to reparse point path: $normTarget"
    }
    $parent = [IO.Path]::GetDirectoryName($normTarget)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -Path $parent -ItemType Directory -Force | Out-Null
    }
    $leaf = [IO.Path]::GetFileName($normTarget)
    $rand = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $tmp = Join-Path $parent "$leaf.tmp.$PID.$rand"
    try {
        [IO.File]::WriteAllText($tmp, $Content, $Encoding)
        if (Test-Path -LiteralPath $normTarget -PathType Leaf) {
            [IO.File]::Replace($tmp, $normTarget, [NullString]::Value)
        } else {
            try {
                [IO.File]::Move($tmp, $normTarget)
            } catch [IO.IOException] {
                [IO.File]::Replace($tmp, $normTarget, [NullString]::Value)
            }
        }
    } finally {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Deploy-RuntimeFiles {
    Assert-SafeInstallDirectory -CandidateDir $InstallDir

    if (-not (Test-Path -LiteralPath $RuntimeSrcDir -PathType Container)) {
        throw "Runtime payload directory missing: $RuntimeSrcDir"
    }

    $requiredFiles = @(
        'launch-hans.ps1',
        'update-hans.ps1',
        'build-overlay.ps1',
        'thought-addon.js',
        'thought-config.default.json',
        'launch-hans.vbs'
    )
    $payloadMap = @{}
    foreach ($rf in $requiredFiles) {
        $srcPath = Join-Path $RuntimeSrcDir $rf
        if (-not (Test-Path -LiteralPath $srcPath -PathType Leaf)) {
            throw "Missing required runtime payload file: $srcPath"
        }
        $payloadMap[$rf] = [IO.File]::ReadAllText($srcPath, [Text.Encoding]::UTF8)
    }

    # Acquire locks in canonical runtime order: UpdaterMutex -> LauncherMutex
    $updLock = $null
    $lchLock = $null
    try {
        $updLock = Enter-MutexOrThrow -Name 'Local\AntigravityHansUpdaterMutex' -TimeoutMs 20000
        $lchLock = Enter-MutexOrThrow -Name 'Local\AntigravityHansLauncherMutex' -TimeoutMs 20000

        if (Test-Path -LiteralPath $InstallDir -PathType Leaf) {
            throw "InstallDir points to an existing file rather than a directory: $InstallDir"
        }
        if (Test-Path -LiteralPath $InstallDir -PathType Container) {
            $existingItems = @(Get-ChildItem -LiteralPath $InstallDir -Force)
            if ($existingItems.Count -gt 0 -and -not (Test-DirectoryOwnedByGuard -DirPath $InstallDir)) {
                throw "Target InstallDir '$InstallDir' already exists, is non-empty, and is not owned by antigravity-zh-plus. Choose a new or empty folder."
            }
        } else {
            New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
        }

        if (Test-PathHasReparsePoint -TargetPath $InstallDir) {
            throw "InstallDir became a reparse point; aborting: $InstallDir"
        }

        $markerJson = ([ordered]@{
            product = 'antigravity-zh-plus'
            schema  = 1
        } | ConvertTo-Json -Depth 2)
        Write-TextAtomically -Path (Join-Path $InstallDir $OwnershipMarkerName) -Content $markerJson -Encoding $Utf8NoBom

        foreach ($psName in @('launch-hans.ps1', 'update-hans.ps1', 'build-overlay.ps1')) {
            Write-TextAtomically -Path (Join-Path $InstallDir $psName) -Content $payloadMap[$psName] -Encoding $Utf8Bom
        }

        Write-TextAtomically -Path (Join-Path $InstallDir 'thought-addon.js') -Content $payloadMap['thought-addon.js'] -Encoding $Utf8NoBom

        $targetCfg = Join-Path $InstallDir 'thought-config.json'
        if (-not (Test-Path -LiteralPath $targetCfg -PathType Leaf)) {
            Write-TextAtomically -Path $targetCfg -Content $payloadMap['thought-config.default.json'] -Encoding $Utf8NoBom
        }

        Write-TextAtomically -Path (Join-Path $InstallDir 'launch-hans.vbs') -Content $payloadMap['launch-hans.vbs'] -Encoding ([Text.Encoding]::ASCII)

        $guardCmdBody = "@echo off`r`n`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"%~dp0launch-hans.ps1`" -InteractiveMenu`r`npause`r`n"
        Write-TextAtomically -Path (Join-Path $InstallDir $GuardCmdName) -Content $guardCmdBody -Encoding ([Text.Encoding]::ASCII)

        $updCmdBody = "@echo off`r`n`"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -File `"%~dp0update-hans.ps1`"`r`npause`r`n"
        Write-TextAtomically -Path (Join-Path $InstallDir $UpdateCmdName) -Content $updCmdBody -Encoding ([Text.Encoding]::ASCII)
    } finally {
        Exit-MutexSafely -MutexObj $lchLock
        Exit-MutexSafely -MutexObj $updLock
    }
}

function Invoke-TargetPs1 {
    param(
        [string]$ScriptName,
        [string[]]$Arguments = @(),
        [switch]$AllowNonZero
    )
    $scriptPath = Join-Path $InstallDir $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Target script not installed at $scriptPath. Run with -Command install first."
    }
    $prevEap = $ErrorActionPreference
    $outputLines = @()
    $code = 1
    try {
        $ErrorActionPreference = 'Continue'
        $outputLines = @(& $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $scriptPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $code = [int]$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if (-not $AllowNonZero -and $code -ne 0) {
        throw "$ScriptName $($Arguments -join ' ') failed (exit $code): $($outputLines -join ' | ')"
    }
    return [pscustomobject]@{
        ExitCode = $code
        Lines    = $outputLines
    }
}

function Get-StructuredState {
    $exePath = Join-Path $InstallDir 'antigravity-hans-windows-amd64.exe'
    $verPath = Join-Path $InstallDir 'VERSION.txt'
    $cfgPath = Join-Path $InstallDir 'thought-config.json'
    $ovPath  = Join-Path $InstallDir 'antigravity-hans-overlay.js'
    $launchPath = Join-Path $InstallDir 'launch-hans.ps1'

    $installed = (Test-Path -LiteralPath $exePath -PathType Leaf) -and (Test-Path -LiteralPath $launchPath -PathType Leaf)
    $ver = if (Test-Path -LiteralPath $verPath -PathType Leaf) { ([IO.File]::ReadAllText($verPath, [Text.Encoding]::UTF8)).Trim() } else { '' }

    $cfgSummary = [ordered]@{
        configValid = $true
        configError = ''
        enabled     = $false
        provider    = 'auto'
        hasApiKey   = $false
        geminiModel = 'gemini-3.5-flash-lite'
    }
    if (Test-Path -LiteralPath $cfgPath -PathType Leaf) {
        try {
            $parsed = ([IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
            if ($null -eq $parsed) {
                $cfgSummary.configValid = $false
                $cfgSummary.configError = 'thought-config.json parsed to null'
            } else {
                if ($null -ne $parsed.PSObject.Properties['enabled']) {
                    if ($parsed.enabled -is [bool]) {
                        $cfgSummary.enabled = $parsed.enabled
                    } else {
                        $cfgSummary.configValid = $false
                        $cfgSummary.configError = "thought-config.json field 'enabled' must be a JSON boolean"
                    }
                }
                if ($null -ne $parsed.PSObject.Properties['provider'] -and $null -ne $parsed.provider) {
                    $cfgSummary.provider = ([string]$parsed.provider).Trim().ToLowerInvariant()
                }
                if ($null -ne $parsed.PSObject.Properties['geminiApiKey'] -and $null -ne $parsed.geminiApiKey) {
                    $cfgSummary.hasApiKey = (-not [string]::IsNullOrWhiteSpace([string]$parsed.geminiApiKey))
                }
                if ($null -ne $parsed.PSObject.Properties['geminiModel'] -and -not [string]::IsNullOrWhiteSpace([string]$parsed.geminiModel)) {
                    $cfgSummary.geminiModel = ([string]$parsed.geminiModel).Trim()
                }
            }
        } catch {
            $cfgSummary.configValid = $false
            $cfgSummary.configError = $_.Exception.Message
        }
    }

    $statusLines = @()
    $statusExitCode = 0
    if (Test-Path -LiteralPath $launchPath -PathType Leaf) {
        $stRes = Invoke-TargetPs1 -ScriptName 'launch-hans.ps1' -Arguments @('-Status')
        $statusLines = $stRes.Lines
        $statusExitCode = $stRes.ExitCode
    }

    return [ordered]@{
        command        = $Command
        installed      = $installed
        ownedByGuard   = (Test-DirectoryOwnedByGuard -DirPath $InstallDir)
        installDir     = $InstallDir
        hansVersion    = $ver
        overlayBuilt   = (Test-Path -LiteralPath $ovPath -PathType Leaf)
        thoughtConfig  = $cfgSummary
        statusExitCode = $statusExitCode
        statusOutput   = $statusLines
        timestampUtc   = [DateTime]::UtcNow.ToString('o')
    }
}

function Update-ProviderConfigUnderLock {
    param([bool]$HasExplicitGeminiModel)

    Assert-SafeInstallDirectory -CandidateDir $InstallDir
    $cfgPath = Join-Path $InstallDir 'thought-config.json'
    $lchLock = $null
    try {
        $lchLock = Enter-MutexOrThrow -Name 'Local\AntigravityHansLauncherMutex' -TimeoutMs 20000

        $cfg = [ordered]@{
            enabled      = $true
            provider     = 'auto'
            geminiApiKey = ''
            geminiModel  = 'gemini-3.5-flash-lite'
        }
        if (Test-Path -LiteralPath $cfgPath -PathType Leaf) {
            $raw = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8)
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $old = $raw | ConvertFrom-Json
                if ($null -ne $old) {
                    foreach ($prop in $old.PSObject.Properties) {
                        $cfg[$prop.Name] = $prop.Value
                    }
                    if ($null -ne $old.PSObject.Properties['enabled']) {
                        if ($old.enabled -is [bool]) {
                            $cfg['enabled'] = $old.enabled
                        } else {
                            throw "Existing thought-config.json has non-boolean 'enabled' value."
                        }
                    }
                    if ($null -ne $old.PSObject.Properties['provider'] -and $null -ne $old.provider) {
                        $cfg['provider'] = ([string]$old.provider).Trim().ToLowerInvariant()
                    }
                    if ($null -ne $old.PSObject.Properties['geminiApiKey'] -and $null -ne $old.geminiApiKey) {
                        $cfg['geminiApiKey'] = ([string]$old.geminiApiKey).Trim()
                    }
                    if ($null -ne $old.PSObject.Properties['geminiModel'] -and -not [string]::IsNullOrWhiteSpace([string]$old.geminiModel)) {
                        $cfg['geminiModel'] = ([string]$old.geminiModel).Trim()
                    } else {
                        $cfg['geminiModel'] = 'gemini-3.5-flash-lite'
                    }
                }
            }
        }

        if ($ThoughtEnabled -eq 'true') { $cfg['enabled'] = $true }
        elseif ($ThoughtEnabled -eq 'false') { $cfg['enabled'] = $false }

        if (-not [string]::IsNullOrWhiteSpace($Provider)) {
            $cfg['provider'] = $Provider.ToLowerInvariant()
        }
        if ($HasExplicitGeminiModel -and -not [string]::IsNullOrWhiteSpace($GeminiModel)) {
            $cfg['geminiModel'] = $GeminiModel.Trim()
        }
        if ($ClearGeminiApiKey) {
            $cfg['geminiApiKey'] = ''
            if ($cfg['provider'] -eq 'gemini') { $cfg['provider'] = 'auto' }
        } elseif (-not [string]::IsNullOrWhiteSpace($GeminiApiKeyEnv)) {
            $envVal = [Environment]::GetEnvironmentVariable($GeminiApiKeyEnv)
            if ([string]::IsNullOrWhiteSpace($envVal)) {
                throw "Environment variable '$GeminiApiKeyEnv' is empty or not set."
            }
            $cfg['geminiApiKey'] = $envVal.Trim()
            if ([string]::IsNullOrWhiteSpace($Provider)) {
                $cfg['provider'] = 'gemini'
            }
        }

        $json = $cfg | ConvertTo-Json -Depth 6
        Write-TextAtomically -Path $cfgPath -Content $json -Encoding $Utf8NoBom
    } finally {
        Exit-MutexSafely -MutexObj $lchLock
    }
}

$HasExplicitModel = $PSBoundParameters.ContainsKey('GeminiModel')
$actionLog = New-Object 'System.Collections.Generic.List[string]'

$mgrLock = $null
try {
    if ($Command -ne 'status') {
        Assert-SafeInstallDirectory -CandidateDir $InstallDir
        $mgrLock = Enter-MutexOrThrow -Name 'Local\AntigravityZhGuardManagerMutex' -TimeoutMs 30000
    }

    switch ($Command) {
        'install' {
            Deploy-RuntimeFiles
            $actionLog.Add("Deployed runtime scripts to $InstallDir")

            if (-not [string]::IsNullOrWhiteSpace($Provider) -or
                -not [string]::IsNullOrWhiteSpace($ThoughtEnabled) -or
                -not [string]::IsNullOrWhiteSpace($GeminiApiKeyEnv) -or
                $ClearGeminiApiKey -or
                $HasExplicitModel) {
                Update-ProviderConfigUnderLock -HasExplicitGeminiModel $HasExplicitModel
                $actionLog.Add('Applied requested thought translation provider settings')
            }

            $updArgs = @()
            if ($ForceUpdate) { $updArgs += '-Force' }
            $updRes = Invoke-TargetPs1 -ScriptName 'update-hans.ps1' -Arguments $updArgs
            foreach ($l in $updRes.Lines) { $actionLog.Add($l) }

            if (-not $NoShortcuts) {
                $scRes = Invoke-TargetPs1 -ScriptName 'launch-hans.ps1' -Arguments @('-SyncShortcuts')
                foreach ($l in $scRes.Lines) { $actionLog.Add($l) }
            } else {
                $actionLog.Add('Skipped shortcut creation (-NoShortcuts)')
            }

            $rbRes = Invoke-TargetPs1 -ScriptName 'launch-hans.ps1' -Arguments @('-RebuildOverlay')
            foreach ($l in $rbRes.Lines) { $actionLog.Add($l) }

            if (-not $NoStartup) {
                $enRes = Invoke-TargetPs1 -ScriptName 'launch-hans.ps1' -Arguments @('-EnableAutoGuard')
                foreach ($l in $enRes.Lines) { $actionLog.Add($l) }
            } else {
                $attRes = Invoke-TargetPs1 -ScriptName 'launch-hans.ps1' -Arguments @('-AttachOnly')
                foreach ($l in $attRes.Lines) { $actionLog.Add($l) }
                $actionLog.Add('Skipped login startup registration (-NoStartup)')
            }
        }

        'status' {
            # Handled below via Get-StructuredState
        }

        'update' {
            Deploy-RuntimeFiles
            $actionLog.Add("Refreshed runtime scripts in $InstallDir")
            $updArgs = @()
            if ($ForceUpdate) { $updArgs += '-Force' }
            $updRes = Invoke-TargetPs1 -ScriptName 'update-hans.ps1' -Arguments $updArgs
            foreach ($l in $updRes.Lines) { $actionLog.Add($l) }
            $rbRes = Invoke-TargetPs1 -ScriptName 'launch-hans.ps1' -Arguments @('-RebuildOverlay')
            foreach ($l in $rbRes.Lines) { $actionLog.Add($l) }
        }

        'set-provider' {
            if (-not (Test-Path -LiteralPath (Join-Path $InstallDir 'launch-hans.ps1') -PathType Leaf)) {
                throw "Runtime is not installed at $InstallDir. Run with -Command install first."
            }
            if (-not (Test-DirectoryOwnedByGuard -DirPath $InstallDir)) {
                throw "Refusing to modify unowned directory: $InstallDir"
            }
            Update-ProviderConfigUnderLock -HasExplicitGeminiModel $HasExplicitModel
            $rbRes = Invoke-TargetPs1 -ScriptName 'launch-hans.ps1' -Arguments @('-RebuildOverlay')
            foreach ($l in $rbRes.Lines) { $actionLog.Add($l) }
        }

        'rebuild' {
            Deploy-RuntimeFiles
            $rbRes = Invoke-TargetPs1 -ScriptName 'launch-hans.ps1' -Arguments @('-RebuildOverlay')
            foreach ($l in $rbRes.Lines) { $actionLog.Add($l) }
        }

        'enable-guard' {
            if (-not (Test-DirectoryOwnedByGuard -DirPath $InstallDir)) {
                throw "Runtime is not installed or directory is not owned by antigravity-zh-plus: $InstallDir"
            }
            $res = Invoke-TargetPs1 -ScriptName 'launch-hans.ps1' -Arguments @('-EnableAutoGuard')
            foreach ($l in $res.Lines) { $actionLog.Add($l) }
            $att = Invoke-TargetPs1 -ScriptName 'launch-hans.ps1' -Arguments @('-AttachOnly')
            foreach ($l in $att.Lines) { $actionLog.Add($l) }
        }

        'disable-guard' {
            if (-not (Test-DirectoryOwnedByGuard -DirPath $InstallDir)) {
                throw "Runtime is not installed or directory is not owned by antigravity-zh-plus: $InstallDir"
            }
            $res = Invoke-TargetPs1 -ScriptName 'launch-hans.ps1' -Arguments @('-DisableAutoGuard')
            foreach ($l in $res.Lines) { $actionLog.Add($l) }
        }

        'stop' {
            if (-not (Test-DirectoryOwnedByGuard -DirPath $InstallDir)) {
                throw "Runtime is not installed or directory is not owned by antigravity-zh-plus: $InstallDir"
            }
            $res = Invoke-TargetPs1 -ScriptName 'launch-hans.ps1' -Arguments @('-StopAll')
            foreach ($l in $res.Lines) { $actionLog.Add($l) }
        }

        'uninstall' {
            if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) {
                $actionLog.Add("InstallDir does not exist (already uninstalled): $InstallDir")
            } else {
                if (-not (Test-DirectoryOwnedByGuard -DirPath $InstallDir)) {
                    throw "Refusing to uninstall '$InstallDir': ownership marker ($OwnershipMarkerName) is missing and directory is not a recognized antigravity-zh-plus installation."
                }

                if (Test-Path -LiteralPath (Join-Path $InstallDir 'launch-hans.ps1') -PathType Leaf) {
                    $res = Invoke-TargetPs1 -ScriptName 'launch-hans.ps1' -Arguments @('-DisableAutoGuard')
                    foreach ($l in $res.Lines) { $actionLog.Add($l) }
                }

                $updLock = $null
                $lchLock = $null
                try {
                    $updLock = Enter-MutexOrThrow -Name 'Local\AntigravityHansUpdaterMutex' -TimeoutMs 20000
                    $lchLock = Enter-MutexOrThrow -Name 'Local\AntigravityHansLauncherMutex' -TimeoutMs 20000

                    $expectedExe = Join-Path $InstallDir 'antigravity-hans-windows-amd64.exe'
                    $procs = @(Get-Process -Name 'antigravity-hans-windows-amd64' -ErrorAction SilentlyContinue)
                    foreach ($p in $procs) {
                        try {
                            if (-not $p.HasExited) {
                                $pPath = $null
                                try { $pPath = [string]$p.Path } catch {}
                                if (-not [string]::IsNullOrWhiteSpace($pPath) -and $pPath.Equals($expectedExe, [System.StringComparison]::OrdinalIgnoreCase)) {
                                    Stop-Process -Id $p.Id -Force -ErrorAction Stop
                                }
                            }
                        } finally {
                            $p.Dispose()
                        }
                    }

                    $expectedVbsArg = '"' + (Join-Path $InstallDir 'launch-hans.vbs') + '"'
                    $wsh = New-Object -ComObject WScript.Shell
                    foreach ($scDir in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs'))) {
                        if ([string]::IsNullOrWhiteSpace($scDir)) { continue }
                        $scPath = Join-Path $scDir $ZhShortcutName
                        if (Test-Path -LiteralPath $scPath -PathType Leaf) {
                            $sc = $wsh.CreateShortcut($scPath)
                            if ($sc.TargetPath.Equals($WscriptPath, [System.StringComparison]::OrdinalIgnoreCase) -and
                                $sc.Arguments.Equals($expectedVbsArg, [System.StringComparison]::OrdinalIgnoreCase)) {
                                Remove-Item -LiteralPath $scPath -Force -ErrorAction Stop
                                $actionLog.Add("Removed owned shortcut: $scPath")
                            } else {
                                $actionLog.Add("Skipped shortcut pointing elsewhere: $scPath")
                            }
                        }
                    }

                    foreach ($fname in $KnownOwnedFiles) {
                        $fpath = Join-Path $InstallDir $fname
                        if (Test-Path -LiteralPath $fpath -PathType Leaf) {
                            $fi = Get-Item -LiteralPath $fpath -Force
                            if (($fi.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                                throw "Refusing to delete reparse point inside InstallDir: $fpath"
                            }
                            Remove-Item -LiteralPath $fpath -Force -ErrorAction Stop
                        }
                    }

                    $remaining = @(Get-ChildItem -LiteralPath $InstallDir -Force)
                    if ($remaining.Count -eq 0) {
                        Remove-Item -LiteralPath $InstallDir -Force -ErrorAction Stop
                        $actionLog.Add("Removed empty installation directory: $InstallDir")
                    } else {
                        $actionLog.Add("Removed runtime files; kept directory '$InstallDir' because $($remaining.Count) user file(s) remain")
                    }

                    if ($InstallDir.Equals($DefaultInstallDir, [System.StringComparison]::OrdinalIgnoreCase)) {
                        $runProp = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'AntigravityHansGuard' -ErrorAction SilentlyContinue
                        if ($null -eq $runProp) {
                            $stateDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'antigravity-hans-guard'
                            if ((Test-Path -LiteralPath $stateDir -PathType Container) -and -not (Test-PathHasReparsePoint -TargetPath $stateDir)) {
                                Remove-Item -LiteralPath $stateDir -Recurse -Force -ErrorAction SilentlyContinue
                                $actionLog.Add("Removed state directory: $stateDir")
                            }
                        }
                    }
                } finally {
                    Exit-MutexSafely -MutexObj $lchLock
                    Exit-MutexSafely -MutexObj $updLock
                }
            }
        }
    }
} finally {
    Exit-MutexSafely -MutexObj $mgrLock
}

$result = if ($Command -eq 'uninstall') {
    [ordered]@{
        command      = 'uninstall'
        installed    = $false
        installDir   = $InstallDir
        actionLog    = $actionLog.ToArray()
        timestampUtc = [DateTime]::UtcNow.ToString('o')
    }
} else {
    $st = Get-StructuredState
    $st['actionLog'] = $actionLog.ToArray()
    $st
}

$jsonOut = $result | ConvertTo-Json -Depth 6
if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
    Write-TextAtomically -Path $OutputFile -Content $jsonOut -Encoding $Utf8NoBom
    Write-Host "Success! Command '$Command' completed. Result written to: $OutputFile"
} else {
    Write-Output $jsonOut
}
