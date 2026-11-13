[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$ToolDir = $PSScriptRoot
$ExeName = 'antigravity-hans-windows-amd64.exe'
$ExePath = Join-Path $ToolDir $ExeName
$BakPath = Join-Path $ToolDir "$ExeName.bak"
$SumPath = Join-Path $ToolDir 'SHA256SUMS'
$VerPath = Join-Path $ToolDir 'VERSION.txt'
$LaunchVbsPath = Join-Path $ToolDir 'launch-hans.vbs'
$LaunchPs1Path = Join-Path $ToolDir 'launch-hans.ps1'
$BuildOverlayPs1 = Join-Path $ToolDir 'build-overlay.ps1'
$OverlayJsPath = Join-Path $ToolDir 'antigravity-hans-overlay.js'
$OverlayMetaPath = Join-Path $ToolDir 'antigravity-hans-overlay.meta.json'
$WscriptPath = Join-Path ([Environment]::SystemDirectory) 'wscript.exe'
$PowerShellExe = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $PowerShellExe -PathType Leaf)) {
    $PowerShellExe = 'powershell.exe'
}
$DesktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Antigravity 中文.lnk'
$StartMenuLnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Antigravity 中文.lnk'
$Headers = @{ 'User-Agent' = 'Antigravity-Hans-Updater' }

function Dispose-ObjectList {
    param([object[]]$Items)
    if ($null -eq $Items) { return }
    foreach ($it in $Items) {
        if ($null -ne $it -and ($it -is [System.IDisposable])) {
            try { $it.Dispose() } catch {}
        }
    }
}

function Test-ShortcutsValid {
    if (-not (Test-Path -LiteralPath $LaunchVbsPath -PathType Leaf) -or -not (Test-Path -LiteralPath $LaunchPs1Path -PathType Leaf)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $DesktopLnk -PathType Leaf) -or -not (Test-Path -LiteralPath $StartMenuLnk -PathType Leaf)) {
        return $false
    }
    $expectedArgs = "`"$LaunchVbsPath`""
    $wsh = New-Object -ComObject WScript.Shell
    foreach ($lnk in @($DesktopLnk, $StartMenuLnk)) {
        $sc = $wsh.CreateShortcut($lnk)
        if ($sc.TargetPath -ne $WscriptPath -or $sc.Arguments -ne $expectedArgs) {
            return $false
        }
    }
    return $true
}

function Sync-Shortcuts {
    if (-not (Test-Path -LiteralPath $LaunchPs1Path -PathType Leaf)) {
        throw "缺少启动脚本: $LaunchPs1Path"
    }
    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $LaunchPs1Path -SyncShortcuts
    if ($LASTEXITCODE -ne 0) {
        throw "调用 launch-hans.ps1 -SyncShortcuts 失败 (退出码: $LASTEXITCODE)。"
    }
    if (-not (Test-ShortcutsValid)) {
        throw "快捷方式目标或参数校验未通过。"
    }
}

function Invoke-BoundedHansStop {
    param([int]$TimeoutMs = 4000)
    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        return
    }
    $stopProc = $null
    try {
        $stopProc = Start-Process -FilePath $ExePath -ArgumentList '--stop' -WorkingDirectory $ToolDir -WindowStyle Hidden -PassThru
        if (-not $stopProc.WaitForExit($TimeoutMs)) {
            try { $stopProc.Kill() } catch {}
            Write-Warning "旧版汉化器 --stop 命令执行超时 ($TimeoutMs ms)，已终止该停止子进程。"
        }
    } catch {
        Write-Warning "调用 --stop 出现异常: $($_.Exception.Message)"
    } finally {
        if ($null -ne $stopProc) { $stopProc.Dispose() }
    }
}

function Get-BlockingHansPids {
    $rawProcs = @()
    $blocking = New-Object 'System.Collections.Generic.List[int]'
    try {
        $rawProcs = @(Get-Process -Name 'antigravity-hans-windows-amd64' -ErrorAction SilentlyContinue)
        foreach ($p in $rawProcs) {
            try {
                if ($p.HasExited) { continue }
                $pPath = $null
                try { $pPath = [string]$p.Path } catch { $pPath = $null }
                # Require confirmed non-matching path to ignore; matching or unreadable path blocks safe replace
                if ([string]::IsNullOrEmpty($pPath) -or $pPath -eq $ExePath) {
                    $blocking.Add([int]$p.Id)
                }
            } catch {}
        }
        return $blocking.ToArray()
    } finally {
        Dispose-ObjectList -Items $rawProcs
    }
}

$ShouldReattachAfterMutex = $false
$UpdaterMutex = New-Object System.Threading.Mutex($false, 'Local\AntigravityHansUpdaterMutex')
$HasUpdaterHandle = $false
$LauncherMutex = $null
$HasLauncherHandle = $false

try {
    try {
        $HasUpdaterHandle = $UpdaterMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $HasUpdaterHandle = $true
    }
    if (-not $HasUpdaterHandle) {
        throw "另一个更新任务正在运行中，请稍后再试。"
    }

    $CurrentTag = 'unknown'
    if (Test-Path -LiteralPath $VerPath -PathType Leaf) {
        $verText = [string](Get-Content -LiteralPath $VerPath -Raw -Encoding UTF8)
        if (-not [string]::IsNullOrWhiteSpace($verText)) {
            $CurrentTag = $verText.Trim()
        }
    }

    Write-Host "[1/4] 正在检查 GitHub 最新版本 (当前记录版本: $CurrentTag)..."
    $Release = Invoke-RestMethod -Uri 'https://api.github.com/repos/yuexps/Antigravity-Hans/releases/latest' -Headers $Headers -TimeoutSec 20
    $LatestTag = [string]$Release.tag_name

    $ExeAsset = $Release.assets | Where-Object { $_.name -eq $ExeName } | Select-Object -First 1
    $SumAsset = $Release.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
    if (-not $ExeAsset -or -not $SumAsset) {
        throw "未在 Release ($LatestTag) 中找到完整的 Windows 二进制资产或 SHA256SUMS。"
    }

    $TmpSum = Join-Path $ToolDir "SHA256SUMS.tmp.$PID"
    $TmpVer = Join-Path $ToolDir "VERSION.txt.tmp.$PID"
    try {
        Invoke-WebRequest -Uri $SumAsset.browser_download_url -Headers $Headers -OutFile $TmpSum -UseBasicParsing -TimeoutSec 30
        $Pattern = '^(?<hash>[0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($ExeName) + '\s*$'
        $MatchesList = @(
            Get-Content -LiteralPath $TmpSum -Encoding UTF8 |
                Where-Object { $_ -match $Pattern }
        )
        if ($MatchesList.Count -ne 1) {
            throw "SHA256SUMS 中 $ExeName 的合法校验条目数量异常 (匹配数: $($MatchesList.Count))。"
        }
        [void]($MatchesList[0] -match $Pattern)
        $ExpectedHash = $Matches['hash'].ToLowerInvariant()

        $LocalMatches = $false
        $PreviousExeHash = ''
        if (Test-Path -LiteralPath $ExePath -PathType Leaf) {
            $PreviousExeHash = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash.ToLowerInvariant()
            $LocalMatches = ($PreviousExeHash -eq $ExpectedHash)
        }
        $ShortcutsOk = Test-ShortcutsValid
        $UpToDate = ($LocalMatches -and $CurrentTag -eq $LatestTag)

        if ($CheckOnly) {
            if ($UpToDate -and $ShortcutsOk) {
                Write-Host "[检测结果] 已是最新且配置完整: 版本=$CurrentTag | 二进制一致=True ($ExpectedHash) | 快捷方式完整=True"
            } else {
                Write-Host "[检测结果] 待更新或待修复: 版本 $CurrentTag -> $LatestTag | 二进制一致=$LocalMatches | 快捷方式完整=$ShortcutsOk"
            }
            return
        }

        if (-not $Force -and $UpToDate) {
            if (-not $ShortcutsOk) {
                Write-Host "[修复] 检测到快捷方式缺失或指向变更，正在自动补建..."
                Sync-Shortcuts
            }
            $ShouldReattachAfterMutex = $true
            Write-Host "[完成] 当前已是最新版本 ($LatestTag)，SHA-256 与快捷方式校验均正常 ($ExpectedHash)。"
            return
        }

        Write-Host "[2/4] 正在下载新版 $ExeName ($LatestTag)..."
        $TmpExe = Join-Path $ToolDir "$ExeName.tmp.$PID"
        try {
            Invoke-WebRequest -Uri $ExeAsset.browser_download_url -Headers $Headers -OutFile $TmpExe -UseBasicParsing -TimeoutSec 180
            $DownloadedHash = (Get-FileHash -LiteralPath $TmpExe -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($DownloadedHash -ne $ExpectedHash) {
                throw "SHA-256 校验失败！预期: $ExpectedHash，实际: $DownloadedHash"
            }

            $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [IO.File]::WriteAllText($TmpVer, $LatestTag, $Utf8NoBom)

            Write-Host "[3/4] SHA-256 校验通过，正在获取启动器操作锁并停止旧版监视器..."
            # Lock hierarchy: UpdaterMutex -> LauncherMutex
            $LauncherMutex = New-Object System.Threading.Mutex($false, 'Local\AntigravityHansLauncherMutex')
            try {
                $HasLauncherHandle = $LauncherMutex.WaitOne(45000)
            } catch [System.Threading.AbandonedMutexException] {
                $HasLauncherHandle = $true
            }
            if (-not $HasLauncherHandle) {
                throw "等待汉化器操作锁超时 (45 秒)，未执行二进制替换。"
            }

            $ShouldReattachAfterMutex = $true
            if (Test-Path -LiteralPath $ExePath -PathType Leaf) {
                Invoke-BoundedHansStop -TimeoutMs 4000
                $swWait = [System.Diagnostics.Stopwatch]::StartNew()
                while ($swWait.ElapsedMilliseconds -lt 10000) {
                    $blockingPids = @(Get-BlockingHansPids)
                    if ($blockingPids.Count -eq 0) { break }
                    Start-Sleep -Milliseconds 300
                }
                $stillBlocking = @(Get-BlockingHansPids)
                if ($stillBlocking.Count -gt 0) {
                    throw "旧版或同目录汉化监视进程 (PID: $($stillBlocking -join ',')) 在 10 秒内未退出，已中止替换以保护原文件。"
                }
            }

            $HadExistingExe = (Test-Path -LiteralPath $ExePath -PathType Leaf)
            $ExeCommitted = $false
            $SumBak = "$SumPath.bak.$PID"
            $VerBak = "$VerPath.bak.$PID"
            if (Test-Path -LiteralPath $SumPath -PathType Leaf) { Copy-Item -LiteralPath $SumPath -Destination $SumBak -Force }
            if (Test-Path -LiteralPath $VerPath -PathType Leaf) { Copy-Item -LiteralPath $VerPath -Destination $VerBak -Force }

            try {
                if ($HadExistingExe) {
                    [IO.File]::Replace($TmpExe, $ExePath, $BakPath, $true)
                } else {
                    Move-Item -LiteralPath $TmpExe -Destination $ExePath -Force
                }
                $ExeCommitted = $true
                Unblock-File -LiteralPath $ExePath -ErrorAction SilentlyContinue

                Move-Item -LiteralPath $TmpSum -Destination $SumPath -Force
                Move-Item -LiteralPath $TmpVer -Destination $VerPath -Force

                if (Test-Path -LiteralPath $BakPath -PathType Leaf) { Remove-Item -LiteralPath $BakPath -Force -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $SumBak -PathType Leaf) { Remove-Item -LiteralPath $SumBak -Force -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $VerBak -PathType Leaf) { Remove-Item -LiteralPath $VerBak -Force -ErrorAction SilentlyContinue }
            } catch {
                $origErr = $_
                if ($ExeCommitted) {
                    try {
                        if ($HadExistingExe -and (Test-Path -LiteralPath $BakPath -PathType Leaf)) {
                            Copy-Item -LiteralPath $BakPath -Destination $ExePath -Force -ErrorAction Stop
                            $restoredHash = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash.ToLowerInvariant()
                            if ($PreviousExeHash -and $restoredHash -ne $PreviousExeHash) {
                                throw "备份恢复后哈希不一致 ($restoredHash != $PreviousExeHash)"
                            }
                            if (Test-Path -LiteralPath $SumBak -PathType Leaf) { Move-Item -LiteralPath $SumBak -Destination $SumPath -Force }
                            if (Test-Path -LiteralPath $VerBak -PathType Leaf) { Move-Item -LiteralPath $VerBak -Destination $VerPath -Force }
                            Write-Warning "更新提交阶段出错，已校验恢复上一版可执行文件与元数据。"
                        } elseif (-not $HadExistingExe -and (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
                            Remove-Item -LiteralPath $ExePath -Force -ErrorAction Stop
                        }
                    } catch {
                        throw "更新失败 ($($origErr.Exception.Message))，且自动回滚时发生二次异常: $($_.Exception.Message)"
                    }
                }
                throw $origErr
            }

            Write-Host "[4/4] 二进制已更新至 $LatestTag，正在合成思考翻译扩展与同步快捷方式..."
            if (Test-Path -LiteralPath $BuildOverlayPs1 -PathType Leaf) {
                try {
                    & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $BuildOverlayPs1 -CallerHoldsMutex
                    if ($LASTEXITCODE -ne 0) {
                        throw "build-overlay.ps1 退出码: $LASTEXITCODE"
                    }
                } catch {
                    $bErr = $_.Exception.Message
                    try {
                        foreach ($stale in @($OverlayJsPath, $OverlayMetaPath)) {
                            if (Test-Path -LiteralPath $stale -PathType Leaf) {
                                Remove-Item -LiteralPath $stale -Force -ErrorAction Stop
                            }
                        }
                        Write-Warning "从新版二进制重新合成思考翻译扩展时告警: $bErr（已清理旧外部脚本，自动回退至新版内嵌汉化）。"
                    } catch {
                        throw "新版合成思考翻译扩展失败 ($bErr)，且隔离旧外部脚本失败: $($_.Exception.Message)"
                    }
                }
            } else {
                foreach ($stale in @($OverlayJsPath, $OverlayMetaPath)) {
                    if (Test-Path -LiteralPath $stale -PathType Leaf) {
                        Remove-Item -LiteralPath $stale -Force -ErrorAction Stop
                    }
                }
            }
            try {
                Sync-Shortcuts
                Write-Host "[成功] 已升级至 $LatestTag！若 Antigravity 正在运行，将自动挂载新版汉化器。"
            } catch {
                Write-Warning "新版二进制 ($LatestTag) 已成功安装，但刷新快捷方式时出错: $($_.Exception.Message)"
            }
        } finally {
            if (Test-Path -LiteralPath $TmpExe -PathType Leaf) {
                Remove-Item -LiteralPath $TmpExe -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        if (Test-Path -LiteralPath $TmpSum -PathType Leaf) {
            Remove-Item -LiteralPath $TmpSum -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $TmpVer -PathType Leaf) {
            Remove-Item -LiteralPath $TmpVer -Force -ErrorAction SilentlyContinue
        }
    }
} finally {
    if ($null -ne $LauncherMutex) {
        if ($HasLauncherHandle) {
            try { $LauncherMutex.ReleaseMutex() } catch {}
        }
        $LauncherMutex.Dispose()
    }
    if ($HasUpdaterHandle) {
        try { $UpdaterMutex.ReleaseMutex() } catch {}
    }
    $UpdaterMutex.Dispose()

    if ($ShouldReattachAfterMutex -and (Test-Path -LiteralPath $LaunchPs1Path -PathType Leaf)) {
        try {
            & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $LaunchPs1Path -AttachOnly
        } catch {}
    }
}
