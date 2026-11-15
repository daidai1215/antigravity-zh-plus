[CmdletBinding()]
param(
    [string]$Repo = '',
    [string]$Branch = 'main',
    [string]$InstallDir = '',
    [switch]$SkipPluginInstall,
    [switch]$NoStartup,
    [switch]$NoShortcuts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# Default GitHub repository slug
$DefaultRepoSlug = if ($env:AGY_ZH_PLUS_REPO) { $env:AGY_ZH_PLUS_REPO } else { 'daidai1215/antigravity-zh-plus' }
$EffectiveRepo = if (-not [string]::IsNullOrWhiteSpace($Repo)) { $Repo.Trim() } else { $DefaultRepoSlug.Trim() }
$EffectiveBranch = if (-not [string]::IsNullOrWhiteSpace($Branch)) { $Branch.Trim() } else { 'main' }

$PowerShellExe = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $PowerShellExe -PathType Leaf)) {
    $PowerShellExe = 'powershell.exe'
}

function Test-PathHasReparsePoint {
    param([string]$TargetPath)
    $full = [IO.Path]::GetFullPath($TargetPath)
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

function Assert-ValidPackageRoot {
    param([string]$PkgRoot)
    $manifestPath = Join-Path $PkgRoot 'plugin.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Invalid package root (missing plugin.json): $PkgRoot"
    }
    $manifest = ([IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
    if ($null -eq $manifest -or $null -eq $manifest.PSObject.Properties['name'] -or [string]$manifest.name -ne 'antigravity-zh-plus') {
        throw "Package identity mismatch in $manifestPath (expected name='antigravity-zh-plus')."
    }
    $requiredRelPaths = @(
        'skills\antigravity-zh-plus\SKILL.md',
        'skills\antigravity-zh-plus\scripts\manage-zh-plus.ps1',
        'skills\antigravity-zh-plus\scripts\runtime\launch-hans.ps1',
        'skills\antigravity-zh-plus\scripts\runtime\launch-hans.vbs',
        'skills\antigravity-zh-plus\scripts\runtime\update-hans.ps1',
        'skills\antigravity-zh-plus\scripts\runtime\build-overlay.ps1',
        'skills\antigravity-zh-plus\scripts\runtime\local-bridge.ps1',
        'skills\antigravity-zh-plus\scripts\runtime\thought-addon.js',
        'skills\antigravity-zh-plus\scripts\runtime\thought-config.default.json'
    )
    foreach ($rel in $requiredRelPaths) {
        $full = Join-Path $PkgRoot $rel
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Incomplete package payload (missing $rel) in: $PkgRoot"
        }
    }
}

function Expand-CheckedGitHubArchive {
    param(
        [string]$ZipPath,
        [string]$DestDir
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    New-Item -Path $DestDir -ItemType Directory -Force | Out-Null
    $destPrefix = ([IO.Path]::GetFullPath($DestDir)).TrimEnd('\') + '\'
    $maxEntries = 512
    $maxTotalBytes = [int64]33554432 # 32 MB ceiling

    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        if ($zip.Entries.Count -le 0 -or $zip.Entries.Count -gt $maxEntries) {
            throw "Unexpected ZIP entry count ($($zip.Entries.Count))."
        }
        $totalBytes = [int64]0
        $seenDestPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $topFolders = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($entry in $zip.Entries) {
            $rawName = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($rawName)) { continue }
            $normRel = $rawName -replace '/', '\'
            if ($normRel.StartsWith('\') -or $normRel.Contains(':')) {
                throw "Rejected unsafe archive entry path: $rawName"
            }
            $segments = $normRel.Split(@('\'), [System.StringSplitOptions]::RemoveEmptyEntries)
            if ($segments.Count -eq 0) { continue }
            foreach ($seg in $segments) {
                if ($seg -eq '.' -or $seg -eq '..') {
                    throw "Rejected traversal archive entry path: $rawName"
                }
            }

            $unixMode = (($entry.ExternalAttributes -shr 16) -band 0xF000)
            $winReparse = ($entry.ExternalAttributes -band 0x0400)
            if ($unixMode -eq 0xA000 -or $winReparse -ne 0) {
                throw "Rejected symlink/reparse archive entry: $rawName"
            }

            $topFolders.Add($segments[0]) | Out-Null
            $targetPath = [IO.Path]::GetFullPath((Join-Path $DestDir $normRel))
            if (-not $targetPath.StartsWith($destPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Archive entry escaped extraction root: $rawName"
            }

            if ($rawName.EndsWith('/') -or $rawName.EndsWith('\')) {
                New-Item -Path $targetPath -ItemType Directory -Force | Out-Null
                continue
            }

            $totalBytes += [int64]$entry.Length
            if ($totalBytes -gt $maxTotalBytes) {
                throw "Archive uncompressed size exceeds 32 MB safety limit."
            }
            if (-not $seenDestPaths.Add($targetPath)) {
                throw "Duplicate normalized archive entry path: $rawName"
            }

            $parentDir = [IO.Path]::GetDirectoryName($targetPath)
            if (-not (Test-Path -LiteralPath $parentDir -PathType Container)) {
                New-Item -Path $parentDir -ItemType Directory -Force | Out-Null
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $false)
        }

        if ($topFolders.Count -ne 1) {
            throw "Expected exactly 1 top-level directory in GitHub archive, found $($topFolders.Count)."
        }
        $pkgDir = Join-Path $DestDir (@($topFolders)[0])
        Assert-ValidPackageRoot -PkgRoot $pkgDir
        return $pkgDir
    } finally {
        $zip.Dispose()
    }
}

$rand = [Guid]::NewGuid().ToString('N').Substring(0, 10)
$TempWorkRoot = Join-Path ([IO.Path]::GetTempPath()) "agy-zh-guard-$PID-$rand"
$SourceRoot = ''

try {
    New-Item -Path $TempWorkRoot -ItemType Directory -Force | Out-Null

    $invPath = ''
    if ($null -ne $MyInvocation -and $null -ne $MyInvocation.MyCommand -and $null -ne $MyInvocation.MyCommand.PSObject.Properties['Path']) {
        $invPath = [string]$MyInvocation.MyCommand.Path
    }

    if (-not [string]::IsNullOrWhiteSpace($invPath) -and (Test-Path -LiteralPath $invPath -PathType Leaf)) {
        $SourceRoot = Split-Path -Parent ([IO.Path]::GetFullPath($invPath))
        Assert-ValidPackageRoot -PkgRoot $SourceRoot
        Write-Host "[1/3] Verified local package source: $SourceRoot"
    } else {
        if ($EffectiveRepo -match '^OWNER/') {
            throw 'Remote repository slug is not configured yet. Clone the repository locally and run .\install.ps1, or pass -Repo "<owner>/<repo>" (or set $env:AGY_ZH_PLUS_REPO).'
        }
        if ($EffectiveRepo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
            throw "Invalid GitHub repository slug: $EffectiveRepo"
        }
        if ($EffectiveBranch -notmatch '^[A-Za-z0-9_./-]+$' -or $EffectiveBranch.Contains('..')) {
            throw "Invalid Git branch name: $EffectiveBranch"
        }

        $zipFile = Join-Path $TempWorkRoot 'repo.zip'
        $unpackDir = Join-Path $TempWorkRoot 'unpacked'
        $zipUrl = "https://github.com/$EffectiveRepo/archive/refs/heads/$EffectiveBranch.zip"

        Write-Host "[1/3] Downloading $EffectiveRepo ($EffectiveBranch) from GitHub..."
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipFile -UseBasicParsing -TimeoutSec 60
        $SourceRoot = Expand-CheckedGitHubArchive -ZipPath $zipFile -DestDir $unpackDir
    }

    $managePs1 = Join-Path $SourceRoot 'skills\antigravity-zh-plus\scripts\manage-zh-plus.ps1'
    $summaryJsonPath = Join-Path $TempWorkRoot 'install-result.json'

    Write-Host "[2/3] Deploying Antigravity-Hans runtime, verifying SHA-256, and building bilingual thinking overlay..."
    $mgrArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $managePs1, '-Command', 'install', '-OutputFile', $summaryJsonPath)
    if (-not [string]::IsNullOrWhiteSpace($InstallDir)) {
        $resolvedInstallDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($InstallDir)
        $mgrArgs += @('-InstallDir', $resolvedInstallDir)
    }
    if ($NoStartup) { $mgrArgs += '-NoStartup' }
    if ($NoShortcuts) { $mgrArgs += '-NoShortcuts' }

    & $PowerShellExe @mgrArgs
    if ($LASTEXITCODE -ne 0) {
        throw "Runtime deployment exited with code $LASTEXITCODE."
    }

    if (-not (Test-Path -LiteralPath $summaryJsonPath -PathType Leaf)) {
        throw "Runtime deployment did not produce result file: $summaryJsonPath"
    }
    $resObj = ([IO.File]::ReadAllText($summaryJsonPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
    if ($null -eq $resObj -or $resObj.installed -ne $true -or $resObj.overlayBuilt -ne $true) {
        throw "Runtime deployment verification failed (installed=$($resObj.installed), overlayBuilt=$($resObj.overlayBuilt))."
    }

    if (-not $SkipPluginInstall) {
        $userHome = [Environment]::GetFolderPath('UserProfile')
        $pluginsRoot = Join-Path $userHome '.gemini\config\plugins'
        $targetPluginDir = Join-Path $pluginsRoot 'antigravity-zh-plus'

        Write-Host "[3/3] Installing Antigravity plugin & skill..."
        if (-not (Test-Path -LiteralPath $pluginsRoot -PathType Container)) {
            New-Item -Path $pluginsRoot -ItemType Directory -Force | Out-Null
        }
        if (Test-PathHasReparsePoint -TargetPath $targetPluginDir) {
            throw "Refusing to install plugin into reparse point path: $targetPluginDir"
        }

        $resolvedSrc = ([IO.Path]::GetFullPath($SourceRoot)).TrimEnd('\')
        $resolvedDst = ([IO.Path]::GetFullPath($targetPluginDir)).TrimEnd('\')
        $srcPrefix = $resolvedSrc + '\'
        $dstPrefix = $resolvedDst + '\'

        if ($resolvedSrc.Equals($resolvedDst, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Host "      Source is already at $targetPluginDir; skipping copy."
        } elseif ($resolvedSrc.StartsWith($dstPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
                  $resolvedDst.StartsWith($srcPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing overlapping plugin source ($resolvedSrc) and destination ($resolvedDst)."
        } else {
            if (Test-Path -LiteralPath $targetPluginDir -PathType Container) {
                $existingManifest = Join-Path $targetPluginDir 'plugin.json'
                $existingItems = @(Get-ChildItem -LiteralPath $targetPluginDir -Force)
                if ($existingItems.Count -gt 0) {
                    $ownedPlugin = $false
                    if (Test-Path -LiteralPath $existingManifest -PathType Leaf) {
                        try {
                            $em = ([IO.File]::ReadAllText($existingManifest, [Text.Encoding]::UTF8)) | ConvertFrom-Json
                            if ($null -ne $em -and [string]$em.name -eq 'antigravity-zh-plus') {
                                $ownedPlugin = $true
                            }
                        } catch {}
                    }
                    if (-not $ownedPlugin) {
                        throw "Existing directory '$targetPluginDir' is non-empty and not an antigravity-zh-plus plugin."
                    }
                }
            }

            $agyCandidates = @(
                (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'agy\bin\agy.exe')
            )
            $cmdAgy = Get-Command 'agy.exe' -ErrorAction SilentlyContinue
            if ($null -ne $cmdAgy -and -not [string]::IsNullOrWhiteSpace($cmdAgy.Source)) {
                $agyCandidates += $cmdAgy.Source
            }
            $agyExe = $agyCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

            $installedViaCli = $false
            if (-not [string]::IsNullOrWhiteSpace($agyExe)) {
                $prevEap = $ErrorActionPreference
                try {
                    $ErrorActionPreference = 'Continue'
                    & $agyExe plugin install $SourceRoot *> $null
                    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath (Join-Path $targetPluginDir 'plugin.json') -PathType Leaf)) {
                        $installedViaCli = $true
                        Write-Host "      Registered via agy CLI: $targetPluginDir"
                    }
                } finally {
                    $ErrorActionPreference = $prevEap
                }
            }

            if (-not $installedViaCli) {
                $stageDir = "$targetPluginDir.stage.$PID.$rand"
                $backupDir = "$targetPluginDir.bak.$PID.$rand"
                try {
                    New-Item -Path $stageDir -ItemType Directory -Force | Out-Null
                    foreach ($item in @('plugin.json', 'README.md', 'LICENSE', 'assets', 'skills')) {
                        $srcItem = Join-Path $SourceRoot $item
                        if (Test-Path -LiteralPath $srcItem) {
                            Copy-Item -LiteralPath $srcItem -Destination (Join-Path $stageDir $item) -Recurse -Force
                        }
                    }
                    Assert-ValidPackageRoot -PkgRoot $stageDir

                    if (Test-Path -LiteralPath $targetPluginDir -PathType Container) {
                        Move-Item -LiteralPath $targetPluginDir -Destination $backupDir -Force
                    }
                    try {
                        Move-Item -LiteralPath $stageDir -Destination $targetPluginDir -Force
                    } catch {
                        if ((Test-Path -LiteralPath $backupDir -PathType Container) -and -not (Test-Path -LiteralPath $targetPluginDir)) {
                            Move-Item -LiteralPath $backupDir -Destination $targetPluginDir -Force -ErrorAction SilentlyContinue
                        }
                        throw
                    }
                    if (Test-Path -LiteralPath $backupDir -PathType Container) {
                        Remove-Item -LiteralPath $backupDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    Write-Host "      Installed plugin files to: $targetPluginDir"
                } finally {
                    if (Test-Path -LiteralPath $stageDir) {
                        Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    } else {
        Write-Host "[3/3] Skipped Antigravity plugin installation (-SkipPluginInstall)."
    }

    Write-Host ""
    foreach ($line in @($resObj.statusOutput)) {
        Write-Host $line
    }
    Write-Host ""
    Write-Host "[OK] Antigravity Chinese Localization + Bilingual Thinking Guard is active!"
} finally {
    if (-not [string]::IsNullOrWhiteSpace($TempWorkRoot) -and (Test-Path -LiteralPath $TempWorkRoot)) {
        Remove-Item -LiteralPath $TempWorkRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
