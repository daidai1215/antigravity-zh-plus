[CmdletBinding()]
param(
    [switch]$Watch,
    [switch]$AttachOnly,
    [switch]$RebuildOverlay,
    [switch]$SyncShortcuts,
    [switch]$EnableAutoGuard,
    [switch]$DisableAutoGuard,
    [switch]$StopAll,
    [switch]$Status,
    [switch]$InteractiveMenu
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$GuardRuntimeVersion = '1.3.0'
$ToolDir = $PSScriptRoot
$HansExeName = 'antigravity-hans-windows-amd64.exe'
$HansExePath = Join-Path $ToolDir $HansExeName
$LaunchVbsPath = Join-Path $ToolDir 'launch-hans.vbs'
$BuildOverlayPs1 = Join-Path $ToolDir 'build-overlay.ps1'
$OverlayJsPath = Join-Path $ToolDir 'antigravity-hans-overlay.js'
$OverlayMetaPath = Join-Path $ToolDir 'antigravity-hans-overlay.meta.json'
$ThoughtCfgPath = Join-Path $ToolDir 'thought-config.json'
$ThoughtAddonPath = Join-Path $ToolDir 'thought-addon.js'
$LocalBridgePs1 = Join-Path $ToolDir 'local-bridge.ps1'
$WscriptPath = Join-Path ([Environment]::SystemDirectory) 'wscript.exe'
$PowerShellExe = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $PowerShellExe -PathType Leaf)) {
    $PowerShellExe = 'powershell.exe'
}

$StateDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'antigravity-hans-guard'
if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) {
    New-Item -Path $StateDir -ItemType Directory -Force | Out-Null
}
$LogPath = Join-Path $StateDir 'launcher.log'
$GuardDisabledFlag = Join-Path $StateDir 'auto-guard.disabled'
$StopSignalFile = Join-Path $StateDir 'watch-stop.signal'
$WatchEndpointFile = Join-Path $StateDir 'watch-endpoint.json'
$BridgeStopSignalFile = Join-Path $StateDir 'bridge-stop.signal'
$BridgeEndpointFile = Join-Path $StateDir 'bridge-endpoint.json'
$LastSpawnFile = Join-Path $StateDir 'last-spawn.json'

$DevToolsPortFile = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Antigravity\DevToolsActivePort'
$DesktopLnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Antigravity 中文.lnk'
$StartMenuLnk = Join-Path ([Environment]::GetFolderPath('Programs')) 'Antigravity 中文.lnk'

$RunRegKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunRegValueName = 'AntigravityHansGuard'

$UpdaterMutexName = 'Local\AntigravityHansUpdaterMutex'
$LauncherMutexName = 'Local\AntigravityHansLauncherMutex'
$WatchMutexName = 'Local\AntigravityHansWatchMutex'
$WatchStopEventName = 'Local\AntigravityHansWatchStopEvent'
$BridgeMutexName = 'Local\AntigravityHansBridgeMutex'
$BridgeStopEventName = 'Local\AntigravityHansBridgeStopEvent'

function Write-LauncherLog {
    param(
        [string]$Message,
        [string]$Scope = 'Launcher'
    )
    try {
        if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
            $fi = Get-Item -LiteralPath $LogPath -ErrorAction SilentlyContinue
            if ($null -ne $fi -and $fi.Length -gt 262144) {
                Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force -ErrorAction SilentlyContinue
            }
        }
        $line = "[{0}] [{1}] {2}{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Scope, $Message, [Environment]::NewLine
        [IO.File]::AppendAllText($LogPath, $line, [Text.Encoding]::UTF8)
    } catch {}
}

function Dispose-ObjectList {
    param([object[]]$Items)
    if ($null -eq $Items) { return }
    foreach ($it in $Items) {
        if ($null -ne $it -and ($it -is [System.IDisposable])) {
            try { $it.Dispose() } catch {}
        }
    }
}

function Test-NamedMutexLocked {
    param([string]$MutexName)
    $m = $null
    $acquired = $false
    try {
        try {
            $m = [System.Threading.Mutex]::OpenExisting($MutexName)
        } catch [System.Threading.WaitHandleCannotBeOpenedException] {
            return $false
        }
        try {
            $acquired = $m.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        return (-not $acquired)
    } finally {
        if ($null -ne $m) {
            if ($acquired) {
                try { $m.ReleaseMutex() } catch {}
            }
            $m.Dispose()
        }
    }
}

function Enter-LauncherMutex {
    param(
        [int]$TimeoutMs = 15000,
        [System.Threading.WaitHandle]$CancelEvent = $null
    )
    $mutex = New-Object System.Threading.Mutex($false, $LauncherMutexName)
    $acquired = $false
    try {
        if ($null -ne $CancelEvent) {
            try {
                $idx = [System.Threading.WaitHandle]::WaitAny(@($mutex, $CancelEvent), $TimeoutMs)
                if ($idx -eq 0 -or $idx -eq 128) {
                    $acquired = $true
                }
            } catch [System.Threading.AbandonedMutexException] {
                $acquired = $true
            }
        } else {
            try {
                $acquired = $mutex.WaitOne($TimeoutMs)
            } catch [System.Threading.AbandonedMutexException] {
                $acquired = $true
            }
        }
        if ($acquired) {
            return $mutex
        }
        $mutex.Dispose()
        return $null
    } catch {
        if ($acquired) {
            try { $mutex.ReleaseMutex() } catch {}
        }
        $mutex.Dispose()
        throw
    }
}

function Exit-LauncherMutex {
    param([System.Threading.Mutex]$Mutex)
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch {}
    $Mutex.Dispose()
}

function Test-WatchCancellationRequested {
    param([System.Threading.EventWaitHandle]$CancelEvent = $null)
    if ((Test-Path -LiteralPath $StopSignalFile -PathType Leaf) -or (Test-Path -LiteralPath $GuardDisabledFlag -PathType Leaf)) {
        return $true
    }
    if ($null -ne $CancelEvent) {
        try {
            if ($CancelEvent.WaitOne(0)) { return $true }
        } catch {}
    }
    return $false
}

function Resolve-AntigravityExe {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if ($env:LOCALAPPDATA) {
        $candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'))
    }
    if ($env:ProgramFiles) {
        $candidates.Add((Join-Path $env:ProgramFiles 'Antigravity\Antigravity.exe'))
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Antigravity\Antigravity.exe'))
    }
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        try {
            if (Test-Path -LiteralPath $c -PathType Leaf) {
                return $c
            }
        } catch {}
    }

    $uninstRoots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $uninstRoots) {
        $items = @()
        try {
            $items = @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue)
        } catch { continue }
        foreach ($item in $items) {
            try {
                $dnProp = $item.PSObject.Properties['DisplayName']
                if ($null -eq $dnProp) { continue }
                $dn = [string]$dnProp.Value
                if ($dn -like 'Antigravity*' -and $dn -notlike '*IDE*') {
                    $locProp = $item.PSObject.Properties['InstallLocation']
                    if ($null -ne $locProp -and -not [string]::IsNullOrWhiteSpace([string]$locProp.Value)) {
                        $exe = Join-Path ([string]$locProp.Value) 'Antigravity.exe'
                        if (Test-Path -LiteralPath $exe -PathType Leaf) {
                            return $exe
                        }
                    }
                }
            } catch {}
        }
    }
    return $null
}

function Read-DevToolsPortCandidate {
    try {
        if (-not [IO.File]::Exists($DevToolsPortFile)) {
            return 0
        }
        $lines = [IO.File]::ReadAllLines($DevToolsPortFile)
        if ($lines.Length -lt 1) {
            return 0
        }
        $port = 0
        if ([int]::TryParse($lines[0].Trim(), [ref]$port) -and $port -ge 1 -and $port -le 65535) {
            return $port
        }
    } catch {}
    return 0
}

function Get-CdpCandidatePorts {
    $list = New-Object 'System.Collections.Generic.List[int]'
    $dtPort = Read-DevToolsPortCandidate
    if ($dtPort -gt 0) {
        $list.Add($dtPort)
    }
    foreach ($p in @(58321, 58322, 58323, 58324, 58325, 9222)) {
        if (-not $list.Contains($p)) {
            $list.Add($p)
        }
    }
    return $list.ToArray()
}

function Invoke-LoopbackHttpGetText {
    param(
        [string]$Url,
        [int]$TimeoutMs = 2000
    )
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = 'GET'
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
    $req.KeepAlive = $false
    $resp = $null
    try {
        $resp = [System.Net.HttpWebResponse]$req.GetResponse()
        if ([int]$resp.StatusCode -ne 200) { return $null }
        $stream = $resp.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8)
        try {
            return $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
            $stream.Dispose()
        }
    } catch [System.Net.WebException] {
        if ($null -ne $_.Exception.Response) {
            try { $_.Exception.Response.Dispose() } catch {}
        }
        return $null
    } finally {
        if ($null -ne $resp) { $resp.Dispose() }
    }
}

function Get-ProcessRemoteDebuggingSwitchState {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return 'Unknown' }
    try {
        $proc = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction Stop
        if ($null -eq $proc -or [string]::IsNullOrWhiteSpace([string]$proc.CommandLine)) { return 'Unknown' }
        $cmd = [string]$proc.CommandLine
        if ($cmd -match '(?i)(?:^|\s)--remote-debugging-port(?:=|\s|$)') {
            return 'HasSwitch'
        }
        return 'MissingSwitch'
    } catch {
        return 'Unknown'
    }
}

function Get-ProcessStartTicksSafe {
    param(
        [int]$ProcessId,
        [string]$ExpectedExePath
    )
    $gp = $null
    try {
        $gp = Get-Process -Id $ProcessId -ErrorAction Stop
        if ($gp.HasExited -or $gp.ProcessName -ne 'Antigravity') { return [int64]0 }
        if ($ExpectedExePath -and [string]$gp.Path -ne $ExpectedExePath) { return [int64]0 }
        return [int64]$gp.StartTime.ToUniversalTime().Ticks
    } catch {
        return [int64]0
    } finally {
        if ($null -ne $gp) { $gp.Dispose() }
    }
}

function Request-GracefulAntigravityQuit {
    param(
        [int]$PreferredPid,
        [int64]$ExpectedStartTicks,
        [string]$ExpectedExePath,
        [int]$TimeoutSeconds = 10
    )
    $gp = $null
    try {
        $gp = Get-Process -Id $PreferredPid -ErrorAction Stop
        if (-not $gp.HasExited -and
            $gp.ProcessName -eq 'Antigravity' -and
            (-not $ExpectedExePath -or [string]$gp.Path -eq $ExpectedExePath) -and
            ($ExpectedStartTicks -le 0 -or $gp.StartTime.ToUniversalTime().Ticks -eq $ExpectedStartTicks)) {
            [void]$gp.CloseMainWindow()
        } else {
            return $false
        }
    } catch {
        return ($null -eq (Get-AntigravityMainProcess -ExpectedExePath $ExpectedExePath))
    } finally {
        if ($null -ne $gp) { $gp.Dispose() }
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $stillMain = Get-AntigravityMainProcess -ExpectedExePath $ExpectedExePath
        if ($null -eq $stillMain) {
            Start-Sleep -Milliseconds 300
            return $true
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Test-RecentLauncherSpawnAlive {
    param([string]$ExpectedExePath)
    try {
        if (-not (Test-Path -LiteralPath $LastSpawnFile -PathType Leaf)) {
            return $null
        }
        $raw = [IO.File]::ReadAllText($LastSpawnFile, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $obj = $raw | ConvertFrom-Json
        $pidProp = $obj.PSObject.Properties['pid']
        $ticksProp = $obj.PSObject.Properties['startTicks']
        $spawnedAtProp = $obj.PSObject.Properties['recordedUtcTicks']
        if ($null -eq $pidProp -or $null -eq $ticksProp -or $null -eq $spawnedAtProp) {
            return $null
        }
        $ageSec = ([DateTime]::UtcNow.Ticks - [int64]$spawnedAtProp.Value) / [double][TimeSpan]::TicksPerSecond
        if ($ageSec -lt 0 -or $ageSec -gt 15) {
            return $null
        }
        $gp = $null
        try {
            $gp = Get-Process -Id ([int]$pidProp.Value) -ErrorAction Stop
            if ($gp.HasExited -or $gp.ProcessName -ne 'Antigravity') { return $null }
            if ($gp.StartTime.ToUniversalTime().Ticks -ne [int64]$ticksProp.Value) { return $null }
            if ($ExpectedExePath) {
                $pPath = [string]$gp.Path
                if ($pPath -ne $ExpectedExePath) { return $null }
            }
            return [pscustomobject]@{
                ProcessId = [uint32]$gp.Id
                CreationDate = $gp.StartTime
                ExecutablePath = $ExpectedExePath
                State = 'StartingByLauncher'
            }
        } catch {
            return $null
        } finally {
            if ($null -ne $gp) { $gp.Dispose() }
        }
    } catch {
        return $null
    }
}

function Save-LauncherSpawnRecord {
    param([System.Diagnostics.Process]$ProcessObj)
    if ($null -eq $ProcessObj) { return }
    try {
        $payload = @{
            pid = [int]$ProcessObj.Id
            startTicks = [int64]$ProcessObj.StartTime.ToUniversalTime().Ticks
            recordedUtcTicks = [int64][DateTime]::UtcNow.Ticks
        } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($LastSpawnFile, $payload, [Text.Encoding]::UTF8)
    } catch {}
}

function Get-VerifiedAntigravityCdpEndpoint {
    param(
        [string]$ExpectedExePath,
        [int[]]$Ports = @()
    )

    $listenRows = @()
    try {
        $listenRows = @(Get-NetTCPConnection -LocalAddress '127.0.0.1' -State Listen -ErrorAction SilentlyContinue)
        $portsToProbe = if ($null -ne $Ports -and $Ports.Count -gt 0) { $Ports } else { @(Get-CdpCandidatePorts) }
        foreach ($port in $portsToProbe) {
            $portListeners = @($listenRows | Where-Object { $_.LocalPort -eq $port })
            if ($portListeners.Count -eq 0) { continue }

            $ownerPid = 0
            $ownerTicks = [int64]0
            foreach ($l in $portListeners) {
                $gp = $null
                try {
                    $gp = Get-Process -Id ([int]$l.OwningProcess) -ErrorAction Stop
                    if ($gp.HasExited -or $gp.ProcessName -ne 'Antigravity') { continue }
                    $pPath = [string]$gp.Path
                    if ($ExpectedExePath -and $pPath -ne $ExpectedExePath) { continue }
                    $ownerPid = [int]$gp.Id
                    $ownerTicks = [int64]$gp.StartTime.ToUniversalTime().Ticks
                    break
                } catch {
                    continue
                } finally {
                    if ($null -ne $gp) { $gp.Dispose() }
                }
            }
            if ($ownerPid -le 0) { continue }

            $wsUrl = $null
            try {
                $content = Invoke-LoopbackHttpGetText -Url "http://127.0.0.1:$port/json/version" -TimeoutMs 2000
                if ([string]::IsNullOrWhiteSpace($content)) { continue }
                $verObj = $content | ConvertFrom-Json
                $wsProp = $verObj.PSObject.Properties['webSocketDebuggerUrl']
                if ($null -eq $wsProp -or [string]::IsNullOrWhiteSpace([string]$wsProp.Value)) { continue }
                $wsCandidate = [string]$wsProp.Value
                $expectedPrefix = "ws://127.0.0.1:$port/devtools/browser/"
                if (-not $wsCandidate.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }
                $wsUrl = $wsCandidate
            } catch {
                continue
            }

            # Re-verify owner process did not exit/reuse PID during HTTP request
            $stillSameOwner = $false
            $gpVerify = $null
            try {
                $gpVerify = Get-Process -Id $ownerPid -ErrorAction Stop
                if (-not $gpVerify.HasExited -and $gpVerify.StartTime.ToUniversalTime().Ticks -eq $ownerTicks) {
                    $stillSameOwner = $true
                }
            } catch {
                $stillSameOwner = $false
            } finally {
                if ($null -ne $gpVerify) { $gpVerify.Dispose() }
            }

            if ($stillSameOwner) {
                return [pscustomobject]@{
                    Port = [int]$port
                    OwnerPid = [int]$ownerPid
                    OwnerStartTicks = [int64]$ownerTicks
                    WebSocketDebuggerUrl = $wsUrl
                }
            }
        }
        return $null
    } finally {
        Dispose-ObjectList -Items $listenRows
    }
}

function Get-AntigravityMainProcess {
    param([string]$ExpectedExePath)

    $cdpEp = Get-VerifiedAntigravityCdpEndpoint -ExpectedExePath $ExpectedExePath
    if ($null -ne $cdpEp) {
        return [pscustomobject]@{
            ProcessId = [uint32]$cdpEp.OwnerPid
            CreationDate = [DateTime]::FromFileTimeUtc(0)
            ExecutablePath = $ExpectedExePath
            CdpPort = [int]$cdpEp.Port
            State = 'ConfirmedCdp'
        }
    }

    $allProcs = @()
    try {
        $allProcs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'Antigravity.exe'" -ErrorAction SilentlyContinue)
        if ($allProcs.Count -eq 0) {
            return $null
        }

        $procById = @{}
        foreach ($p in $allProcs) {
            $procById[[uint32]$p.ProcessId] = $p
        }

        $typedParentPids = New-Object 'System.Collections.Generic.HashSet[uint32]'
        foreach ($p in $allProcs) {
            $cmd = [string]$p.CommandLine
            if ($cmd -match '(?:^|\s)--type=') {
                $parentId = [uint32]$p.ParentProcessId
                if ($procById.ContainsKey($parentId)) {
                    $parentProc = $procById[$parentId]
                    $parentExe = [string]$parentProc.ExecutablePath
                    $childExe = [string]$p.ExecutablePath
                    $timeValid = $true
                    if (($parentProc.CreationDate -is [DateTime]) -and ($p.CreationDate -is [DateTime])) {
                        $timeValid = ($parentProc.CreationDate -le $p.CreationDate.AddSeconds(1))
                    }
                    if ($timeValid -and (-not $ExpectedExePath -or ($parentExe -eq $ExpectedExePath -and $childExe -eq $ExpectedExePath))) {
                        [void]$typedParentPids.Add($parentId)
                    }
                }
            }
        }

        $matched = New-Object 'System.Collections.Generic.List[object]'
        foreach ($p in $allProcs) {
            $exePath = [string]$p.ExecutablePath
            if ($ExpectedExePath -and $exePath -ne $ExpectedExePath) {
                continue
            }
            $cmd = [string]$p.CommandLine
            if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
            if ($cmd -match '(?:^|\s)--type=') { continue }
            if ($cmd -match '(?:^|\s)--import(?:=|\s|$)') { continue }

            $procId = [uint32]$p.ProcessId
            $isConfirmed = $typedParentPids.Contains($procId)
            if (-not $isConfirmed) {
                $gp = $null
                try {
                    $gp = Get-Process -Id ([int]$procId) -ErrorAction Stop
                    if (-not $gp.HasExited -and $gp.MainWindowHandle -ne [IntPtr]::Zero) {
                        $isConfirmed = $true
                    }
                } catch {
                    $isConfirmed = $false
                } finally {
                    if ($null -ne $gp) { $gp.Dispose() }
                }
            }

            if ($isConfirmed) {
                $matched.Add([pscustomobject]@{
                    ProcessId = $procId
                    CreationDate = $(if ($p.CreationDate -is [DateTime]) { $p.CreationDate } else { [DateTime]::MinValue })
                    ExecutablePath = $exePath
                    CdpPort = 0
                    State = 'ConfirmedUi'
                })
            }
        }

        if ($matched.Count -gt 0) {
            return ($matched | Sort-Object -Property CreationDate -Descending | Select-Object -First 1)
        }

        return (Test-RecentLauncherSpawnAlive -ExpectedExePath $ExpectedExePath)
    } finally {
        Dispose-ObjectList -Items $allProcs
    }
}

function Set-ProcessWindowForeground {
    param([int]$PreferredPid = 0)
    try {
        if (-not ('AntigravityWin32.FocusHelper' -as [type])) {
            Add-Type -Namespace 'AntigravityWin32' -Name 'FocusHelper' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsIconic(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindowAsync(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
'@ -ErrorAction Stop
        }

        $targetHwnd = [IntPtr]::Zero
        if ($PreferredPid -gt 0) {
            $gp = $null
            try {
                $gp = Get-Process -Id $PreferredPid -ErrorAction Stop
                if (-not $gp.HasExited -and $gp.MainWindowHandle -ne [IntPtr]::Zero) {
                    $targetHwnd = $gp.MainWindowHandle
                }
            } catch {} finally {
                if ($null -ne $gp) { $gp.Dispose() }
            }
        }
        if ($targetHwnd -eq [IntPtr]::Zero) {
            $allAg = @()
            try {
                $allAg = @(Get-Process -Name 'Antigravity' -ErrorAction SilentlyContinue)
                foreach ($item in $allAg) {
                    try {
                        if (-not $item.HasExited -and $item.MainWindowHandle -ne [IntPtr]::Zero) {
                            $targetHwnd = $item.MainWindowHandle
                            break
                        }
                    } catch {}
                }
            } finally {
                Dispose-ObjectList -Items $allAg
            }
        }
        if ($targetHwnd -ne [IntPtr]::Zero) {
            if ([AntigravityWin32.FocusHelper]::IsIconic($targetHwnd)) {
                [void][AntigravityWin32.FocusHelper]::ShowWindowAsync($targetHwnd, 9)
            }
            [void][AntigravityWin32.FocusHelper]::SetForegroundWindow($targetHwnd)
        }
    } catch {}
}

function Get-ConfirmedHansProcesses {
    $rawProcs = @()
    $confirmed = New-Object 'System.Collections.Generic.List[object]'
    try {
        $rawProcs = @(Get-Process -Name 'antigravity-hans-windows-amd64' -ErrorAction SilentlyContinue)
        foreach ($p in $rawProcs) {
            try {
                if ($p.HasExited) { continue }
                $pPath = [string]$p.Path
                if ($pPath -eq $HansExePath) {
                    $confirmed.Add([pscustomobject]@{
                        Id = [int]$p.Id
                        StartTicks = [int64]$p.StartTime.ToUniversalTime().Ticks
                    })
                }
            } catch {}
        }
        return $confirmed.ToArray()
    } finally {
        Dispose-ObjectList -Items $rawProcs
    }
}

function Get-AttachedHansInfo {
    param([int]$Port)
    if ($Port -le 0) { return $null }

    $hansList = @(Get-ConfirmedHansProcesses)
    if ($hansList.Count -eq 0) {
        return $null
    }

    $byPid = @{}
    foreach ($hp in $hansList) {
        $byPid[[uint32]$hp.Id] = $hp
    }

    $conns = @()
    try {
        $conns = @(Get-NetTCPConnection -RemoteAddress '127.0.0.1' -RemotePort $Port -State Established -ErrorAction SilentlyContinue)
        foreach ($c in $conns) {
            $ownerId = [uint32]$c.OwningProcess
            if ($byPid.ContainsKey($ownerId)) {
                return $byPid[$ownerId]
            }
        }
        return $null
    } finally {
        Dispose-ObjectList -Items $conns
    }
}

function Invoke-HansStopBounded {
    param([int]$TimeoutMs = 3000)
    if (-not (Test-Path -LiteralPath $HansExePath -PathType Leaf)) {
        return
    }
    $stopProc = $null
    try {
        $stopProc = Start-Process -FilePath $HansExePath -ArgumentList '--stop' -WorkingDirectory $ToolDir -WindowStyle Hidden -PassThru
        if (-not $stopProc.WaitForExit($TimeoutMs)) {
            try { $stopProc.Kill() } catch {}
            Write-LauncherLog -Scope 'Stop' -Message "执行 --stop 超时 ($TimeoutMs ms)，已终止停止子进程。"
        }
    } catch {
        Write-LauncherLog -Scope 'Stop' -Message "执行 --stop 异常: $($_.Exception.Message)"
    } finally {
        if ($null -ne $stopProc) { $stopProc.Dispose() }
    }
}

function Stop-HansMonitors {
    Invoke-HansStopBounded -TimeoutMs 3000
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 3000) {
        $alive = @(Get-ConfirmedHansProcesses)
        if ($alive.Count -eq 0) { return }
        Start-Sleep -Milliseconds 200
    }
    $leftover = @(Get-ConfirmedHansProcesses)
    foreach ($proc in $leftover) {
        $gp = $null
        try {
            $gp = Get-Process -Id $proc.Id -ErrorAction Stop
            if (-not $gp.HasExited -and [string]$gp.Path -eq $HansExePath -and $gp.StartTime.ToUniversalTime().Ticks -eq $proc.StartTicks) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {} finally {
            if ($null -ne $gp) { $gp.Dispose() }
        }
    }
}

function Stop-HansMonitorsSynchronized {
    $mutex = Enter-LauncherMutex -TimeoutMs 15000
    if ($null -eq $mutex) {
        throw "获取汉化器操作锁超时，未能执行停止操作。"
    }
    try {
        Stop-HansMonitors
    } finally {
        Exit-LauncherMutex -Mutex $mutex
    }
}

function ConvertTo-StrictBoolValue {
    param($Value, [bool]$DefaultVal)
    if ($null -eq $Value) { return $DefaultVal }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        $t = $Value.Trim().ToLowerInvariant()
        if ($t -eq 'true') { return $true }
        if ($t -eq 'false') { return $false }
    }
    throw "布尔字段值非法: $Value"
}

function Read-ThoughtConfigNormalized {
    param([switch]$Strict)
    $defaults = [ordered]@{
        enabled      = $true
        provider     = 'auto'
        bridgePort   = 47831
        bridgeToken  = ''
        llmApiKey    = ''
        llmBaseUrl   = 'https://open.bigmodel.cn/api/paas/v4/chat/completions'
        llmModel     = 'glm-4-flash'
        geminiApiKey = ''
        geminiModel  = 'gemini-3.5-flash-lite'
    }
    if (-not (Test-Path -LiteralPath $ThoughtCfgPath -PathType Leaf)) {
        return $defaults
    }
    try {
        $utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
        $raw = [IO.File]::ReadAllText($ThoughtCfgPath, $utf8Strict)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            if ($Strict) { throw "thought-config.json 内容为空。" }
            return $defaults
        }
        $obj = $raw | ConvertFrom-Json
        if ($null -eq $obj -or ($obj -is [Array]) -or ($obj -is [ValueType]) -or ($obj -is [string])) {
            throw "thought-config.json 根节点不是 JSON 对象。"
        }
        foreach ($prop in $obj.PSObject.Properties) {
            $defaults[$prop.Name] = $prop.Value
        }
        if ($null -ne $obj.PSObject.Properties['enabled'] -and $null -ne $obj.enabled) {
            $defaults['enabled'] = ConvertTo-StrictBoolValue -Value $obj.enabled -DefaultVal $true
        } else {
            $defaults['enabled'] = $true
        }
        if ($null -ne $obj.PSObject.Properties['provider'] -and $null -ne $obj.provider) {
            $pv = ([string]$obj.provider).Trim().ToLowerInvariant()
            if ($pv -in @('auto', 'free-direct', 'google-free', 'zhipu', 'openai-compat', 'local-llm', 'gemini')) {
                $defaults['provider'] = $pv
            } elseif ($Strict) {
                throw "非法 provider: $pv"
            } else {
                $defaults['provider'] = 'auto'
            }
        } else {
            $defaults['provider'] = 'auto'
        }
        $bp = 0
        if ($null -ne $obj.PSObject.Properties['bridgePort'] -and [int]::TryParse([string]$obj.bridgePort, [ref]$bp) -and $bp -ge 1024 -and $bp -le 65535) {
            $defaults['bridgePort'] = $bp
        } else {
            $defaults['bridgePort'] = 47831
        }
        $defaults['bridgeToken'] = if ($null -ne $obj.PSObject.Properties['bridgeToken'] -and $null -ne $obj.bridgeToken) { ([string]$obj.bridgeToken).Trim() } else { '' }
        $defaults['llmApiKey'] = if ($null -ne $obj.PSObject.Properties['llmApiKey'] -and $null -ne $obj.llmApiKey) { ([string]$obj.llmApiKey).Trim() } else { '' }
        if ($null -ne $obj.PSObject.Properties['llmBaseUrl'] -and -not [string]::IsNullOrWhiteSpace([string]$obj.llmBaseUrl)) {
            $defaults['llmBaseUrl'] = ([string]$obj.llmBaseUrl).Trim()
        } else {
            $defaults['llmBaseUrl'] = 'https://open.bigmodel.cn/api/paas/v4/chat/completions'
        }
        if ($null -ne $obj.PSObject.Properties['llmModel'] -and -not [string]::IsNullOrWhiteSpace([string]$obj.llmModel)) {
            $defaults['llmModel'] = ([string]$obj.llmModel).Trim()
        } else {
            $defaults['llmModel'] = 'glm-4-flash'
        }
        $defaults['geminiApiKey'] = if ($null -ne $obj.PSObject.Properties['geminiApiKey'] -and $null -ne $obj.geminiApiKey) { ([string]$obj.geminiApiKey).Trim() } else { '' }
        if ($null -ne $obj.PSObject.Properties['geminiModel'] -and -not [string]::IsNullOrWhiteSpace([string]$obj.geminiModel)) {
            $defaults['geminiModel'] = ([string]$obj.geminiModel).Trim()
        } else {
            $defaults['geminiModel'] = 'gemini-3.5-flash-lite'
        }
        return $defaults
    } catch {
        if ($Strict) { throw }
        return $null
    }
}

function Save-ThoughtConfigNormalized {
    param([System.Collections.IDictionary]$ConfigMap)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $json = $ConfigMap | ConvertTo-Json -Depth 4
    $rand = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $tmp = Join-Path $ToolDir "thought-config.json.tmp.$PID.$rand"
    try {
        [IO.File]::WriteAllText($tmp, $json, $utf8NoBom)
        if (Test-Path -LiteralPath $ThoughtCfgPath -PathType Leaf) {
            [IO.File]::Replace($tmp, $ThoughtCfgPath, [NullString]::Value)
        } else {
            try {
                [IO.File]::Move($tmp, $ThoughtCfgPath)
            } catch [IO.IOException] {
                [IO.File]::Replace($tmp, $ThoughtCfgPath, [NullString]::Value)
            }
        }
    } finally {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ThoughtTranslationSummary {
    if (-not (Test-Path -LiteralPath $ThoughtAddonPath -PathType Leaf)) {
        return '未安装扩展文件 (thought-addon.js)'
    }
    $cfg = Read-ThoughtConfigNormalized
    if ($null -eq $cfg) {
        return '配置文件格式错误 (请检查 thought-config.json 或通过菜单 [4] 重置)'
    }
    if (-not $cfg.enabled) {
        return '已关闭 (仅基础界面汉化)'
    }
    $hasLlmKey = (-not [string]::IsNullOrWhiteSpace($cfg.llmApiKey))
    $hasGemKey = (-not [string]::IsNullOrWhiteSpace($cfg.geminiApiKey))
    $pv = [string]$cfg.provider

    $srcDesc = if ($pv -eq 'local-llm') {
        "本机离线翻译模型 ($($cfg.llmModel) @ $($cfg.llmBaseUrl), 异常自动回退本地直连桥)"
    } elseif ($hasLlmKey -and $pv -in @('zhipu', 'openai-compat', 'auto')) {
        $tail = if ($cfg.llmApiKey.Length -ge 4) { $cfg.llmApiKey.Substring($cfg.llmApiKey.Length - 4) } else { '****' }
        $label = if ($pv -eq 'zhipu' -or $cfg.llmBaseUrl -match 'bigmodel\.cn') { '智谱官方免费大模型' } else { '独立大模型 API' }
        "$label ($($cfg.llmModel), Key 尾号: $tail, 异常自动回退本地直连桥)"
    } elseif ($hasGemKey -and $pv -in @('gemini', 'auto')) {
        $tail = if ($cfg.geminiApiKey.Length -ge 4) { $cfg.geminiApiKey.Substring($cfg.geminiApiKey.Length - 4) } else { '****' }
        "官方 Gemini API ($($cfg.geminiModel), Key 尾号: $tail, 异常自动回退本地直连桥)"
    } else {
        "免Key本地免代理直连 + 多段打包 (127.0.0.1:$($cfg.bridgePort) -> 腾讯 TranSmart, 防代理429)"
    }
    return "已启用 | 中英对照 | 翻译源: $srcDesc"
}

function Remove-StaleExternalOverlay {
    foreach ($f in @($OverlayJsPath, $OverlayMetaPath)) {
        if (Test-Path -LiteralPath $f -PathType Leaf) {
            Remove-Item -LiteralPath $f -Force -ErrorAction Stop
        }
    }
}

function Test-OverlayMetaMatchesInputs {
    if (-not (Test-Path -LiteralPath $OverlayJsPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $OverlayMetaPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $ThoughtCfgPath -PathType Leaf)) {
        return $false
    }
    try {
        $meta = ([IO.File]::ReadAllText($OverlayMetaPath, [Text.Encoding]::UTF8)) | ConvertFrom-Json
        if ($null -eq $meta) { return $false }
        $exeSha = (Get-FileHash -LiteralPath $HansExePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $addonSha = (Get-FileHash -LiteralPath $ThoughtAddonPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $cfgSha = (Get-FileHash -LiteralPath $ThoughtCfgPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $ovSha = (Get-FileHash -LiteralPath $OverlayJsPath -Algorithm SHA256).Hash.ToLowerInvariant()
        return (
            [string]$meta.exeSha -eq $exeSha -and
            [string]$meta.addonSha -eq $addonSha -and
            [string]$meta.configSha -eq $cfgSha -and
            [string]$meta.overlaySha -eq $ovSha
        )
    } catch {
        return $false
    }
}

function Ensure-OverlayReady {
    param(
        [switch]$ForceRebuild,
        [switch]$CallerHoldsLauncherMutex,
        [string]$Scope = 'Overlay'
    )
    if (-not (Test-Path -LiteralPath $BuildOverlayPs1 -PathType Leaf) -or
        -not (Test-Path -LiteralPath $ThoughtAddonPath -PathType Leaf)) {
        try {
            Remove-StaleExternalOverlay
        } catch {
            Write-LauncherLog -Scope $Scope -Message "缺少构建器且无法清理旧外部 overlay: $($_.Exception.Message)"
        }
        return [pscustomobject]@{
            Available = $false
            Rebuilt   = $false
        }
    }

    $needBuild = [bool]$ForceRebuild
    if (-not $needBuild) {
        if (-not (Test-OverlayMetaMatchesInputs)) {
            $needBuild = $true
        }
    }

    if ($needBuild) {
        try {
            $buildArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $BuildOverlayPs1, '-Quiet')
            if ($CallerHoldsLauncherMutex) {
                $buildArgs += '-CallerHoldsMutex'
            }
            & $PowerShellExe @buildArgs
            if ($LASTEXITCODE -ne 0) {
                throw "build-overlay.ps1 退出码: $LASTEXITCODE"
            }
            Write-LauncherLog -Scope $Scope -Message "已合成最新外部汉化与思考翻译脚本 (antigravity-hans-overlay.js)。"
            return [pscustomobject]@{
                Available = (Test-Path -LiteralPath $OverlayJsPath -PathType Leaf)
                Rebuilt   = $true
            }
        } catch {
            $buildErr = $_.Exception.Message
            try {
                Remove-StaleExternalOverlay
                Write-LauncherLog -Scope $Scope -Message "合成外部 overlay 失败 ($buildErr)，已隔离旧外部脚本并安全回退内嵌汉化。"
            } catch {
                Write-LauncherLog -Scope $Scope -Message "合成外部 overlay 失败 ($buildErr)，且清理旧文件异常: $($_.Exception.Message)"
            }
            return [pscustomobject]@{
                Available = $false
                Rebuilt   = $false
            }
        }
    }

    return [pscustomobject]@{
        Available = $true
        Rebuilt   = $false
    }
}

function Ensure-HansAttached {
    param(
        [string]$ExpectedAntigravityExe,
        [int]$WaitPortSeconds = 25,
        [string]$Scope = 'Launcher',
        [System.Threading.EventWaitHandle]$CancelEvent = $null,
        [switch]$CallerHoldsLauncherMutex,
        [switch]$ForceReattach,
        [switch]$SkipOverlayBuild
    )

    $emptyResult = [pscustomobject]@{ Attached = $false; Port = 0; HansPid = 0; HansStartTicks = [int64]0; OwnerPid = 0; OwnerStartTicks = [int64]0 }

    if (-not (Test-Path -LiteralPath $HansExePath -PathType Leaf)) {
        Write-LauncherLog -Scope $Scope -Message "未找到汉化器可执行文件: $HansExePath"
        return $emptyResult
    }

    if ($null -ne $CancelEvent -and (Test-WatchCancellationRequested -CancelEvent $CancelEvent)) {
        return $emptyResult
    }

    if (Test-NamedMutexLocked -MutexName $UpdaterMutexName) {
        Write-LauncherLog -Scope $Scope -Message "检测到更新任务正在运行，避让本次挂载。"
        return $emptyResult
    }

    $mutex = $null
    if (-not $CallerHoldsLauncherMutex) {
        $mutex = Enter-LauncherMutex -TimeoutMs 15000 -CancelEvent $CancelEvent
        if ($null -eq $mutex) {
            return $emptyResult
        }
    }

    try {
        if ($null -ne $CancelEvent -and (Test-WatchCancellationRequested -CancelEvent $CancelEvent)) {
            return $emptyResult
        }
        if (Test-NamedMutexLocked -MutexName $UpdaterMutexName) {
            return $emptyResult
        }

        $overlayState = if ($SkipOverlayBuild) {
            [pscustomobject]@{
                Available = (Test-Path -LiteralPath $OverlayJsPath -PathType Leaf)
                Rebuilt   = $false
            }
        } else {
            Ensure-OverlayReady -ForceRebuild:$ForceReattach -CallerHoldsLauncherMutex -Scope $Scope
        }

        $cdpEp = $null
        $swPort = [System.Diagnostics.Stopwatch]::StartNew()
        $budgetMs = [Math]::Max(500, $WaitPortSeconds * 1000)
        while ($true) {
            if ($null -ne $CancelEvent -and (Test-WatchCancellationRequested -CancelEvent $CancelEvent)) {
                return $emptyResult
            }
            $cdpEp = Get-VerifiedAntigravityCdpEndpoint -ExpectedExePath $ExpectedAntigravityExe
            if ($null -ne $cdpEp) { break }
            if ($swPort.ElapsedMilliseconds -ge $budgetMs) { break }
            Start-Sleep -Milliseconds 300
        }

        if ($null -eq $cdpEp) {
            Write-LauncherLog -Scope $Scope -Message "等待 Antigravity 浏览器 CDP 端口超时 ($WaitPortSeconds 秒)。"
            return $emptyResult
        }

        $port = [int]$cdpEp.Port
        $existingHans = Get-AttachedHansInfo -Port $port
        if ($null -ne $existingHans) {
            $overlayOutdated = $false
            if ($ForceReattach -or $overlayState.Rebuilt) {
                $overlayOutdated = $true
            } elseif ($overlayState.Available -and (Test-Path -LiteralPath $OverlayJsPath -PathType Leaf)) {
                $ovTicks = (Get-Item -LiteralPath $OverlayJsPath).LastWriteTimeUtc.Ticks
                if (($ovTicks - $existingHans.StartTicks) -gt 500000) {
                    $overlayOutdated = $true
                }
            }

            if (-not $overlayOutdated) {
                return [pscustomobject]@{
                    Attached = $true
                    Port = $port
                    HansPid = [int]$existingHans.Id
                    HansStartTicks = [int64]$existingHans.StartTicks
                    OwnerPid = [int]$cdpEp.OwnerPid
                    OwnerStartTicks = [int64]$cdpEp.OwnerStartTicks
                }
            }
            Write-LauncherLog -Scope $Scope -Message "检测到外部汉化/思考翻译脚本已更新，正在热重载汉化监视器..."
        }

        if ($null -ne $CancelEvent -and (Test-WatchCancellationRequested -CancelEvent $CancelEvent)) {
            return $emptyResult
        }

        Stop-HansMonitors

        if ($null -ne $CancelEvent -and (Test-WatchCancellationRequested -CancelEvent $CancelEvent)) {
            return $emptyResult
        }

        $hansArgs = @('--app', '--attach-only', '--nogui')
        if ($overlayState.Available) {
            $hansArgs += '--trust-external-overlay'
        }

        $spawnedHans = $null
        try {
            $spawnedHans = Start-Process -FilePath $HansExePath -ArgumentList $hansArgs -WorkingDirectory $ToolDir -WindowStyle Hidden -PassThru
        } finally {
            if ($null -ne $spawnedHans) { $spawnedHans.Dispose() }
        }

        $swAttach = [System.Diagnostics.Stopwatch]::StartNew()
        while ($swAttach.ElapsedMilliseconds -lt 6000) {
            if ($null -ne $CancelEvent -and (Test-WatchCancellationRequested -CancelEvent $CancelEvent)) {
                Stop-HansMonitors
                return $emptyResult
            }
            $attachedInfo = Get-AttachedHansInfo -Port $port
            if ($null -ne $attachedInfo) {
                $modeTag = if ($overlayState.Available) { '含思考与动作汉化' } else { '基础内嵌汉化' }
                Write-LauncherLog -Scope $Scope -Message "已建立汉化监视连接 ($modeTag, PID: $($attachedInfo.Id) -> 127.0.0.1:$port, 宿主 PID: $($cdpEp.OwnerPid))"
                return [pscustomobject]@{
                    Attached = $true
                    Port = $port
                    HansPid = [int]$attachedInfo.Id
                    HansStartTicks = [int64]$attachedInfo.StartTicks
                    OwnerPid = [int]$cdpEp.OwnerPid
                    OwnerStartTicks = [int64]$cdpEp.OwnerStartTicks
                }
            }
            Start-Sleep -Milliseconds 250
        }

        Write-LauncherLog -Scope $Scope -Message "已启动汉化监视器，但 6 秒内未检测到端口 $port 的连接。"
        return $emptyResult
    } finally {
        if (-not $CallerHoldsLauncherMutex -and $null -ne $mutex) {
            Exit-LauncherMutex -Mutex $mutex
        }
    }
}

function Sync-LauncherShortcuts {
    param([string]$AntigravityExe)
    if (-not (Test-Path -LiteralPath $LaunchVbsPath -PathType Leaf)) {
        throw "未找到启动器包装脚本: $LaunchVbsPath"
    }
    $iconPath = if ($AntigravityExe -and (Test-Path -LiteralPath $AntigravityExe -PathType Leaf)) {
        "$AntigravityExe,0"
    } else {
        "$HansExePath,0"
    }

    $wsh = New-Object -ComObject WScript.Shell
    foreach ($lnkPath in @($DesktopLnk, $StartMenuLnk)) {
        $sc = $wsh.CreateShortcut($lnkPath)
        $sc.TargetPath = $WscriptPath
        $sc.Arguments = "`"$LaunchVbsPath`""
        $sc.WorkingDirectory = $ToolDir
        $sc.IconLocation = $iconPath
        $sc.Description = 'Antigravity 中文版 (自动动态汉化)'
        $sc.WindowStyle = 1
        $sc.Save()
    }
}

function Test-StartupGuardRegistered {
    $prop = Get-ItemProperty -LiteralPath $RunRegKey -Name $RunRegValueName -ErrorAction SilentlyContinue
    if ($null -eq $prop) { return $false }
    $valProp = $prop.PSObject.Properties[$RunRegValueName]
    return ($null -ne $valProp -and -not [string]::IsNullOrWhiteSpace([string]$valProp.Value))
}

function Set-StartupGuardRegistration {
    param([bool]$Enable)
    if ($Enable) {
        if (-not (Test-Path -LiteralPath $RunRegKey)) {
            New-Item -Path $RunRegKey -Force | Out-Null
        }
        $cmdValue = "`"$WscriptPath`" `"$LaunchVbsPath`" -Watch"
        Set-ItemProperty -LiteralPath $RunRegKey -Name $RunRegValueName -Value $cmdValue -Type String
        if (Test-Path -LiteralPath $GuardDisabledFlag -PathType Leaf) {
            Remove-Item -LiteralPath $GuardDisabledFlag -Force -ErrorAction SilentlyContinue
        }
    } else {
        Remove-ItemProperty -LiteralPath $RunRegKey -Name $RunRegValueName -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText($GuardDisabledFlag, 'disabled', [Text.Encoding]::ASCII)
    }
}

function Get-ActiveLocalBridgePort {
    if (-not (Test-NamedMutexLocked -MutexName $BridgeMutexName)) {
        return 0
    }
    if (Test-Path -LiteralPath $BridgeEndpointFile -PathType Leaf) {
        try {
            $ep = ([IO.File]::ReadAllText($BridgeEndpointFile, [Text.Encoding]::UTF8)) | ConvertFrom-Json
            if ($null -ne $ep -and $null -ne $ep.PSObject.Properties['port']) {
                return [int]$ep.port
            }
        } catch {}
    }
    $cfg = Read-ThoughtConfigNormalized
    return $(if ($null -ne $cfg) { [int]$cfg.bridgePort } else { 47831 })
}

function Start-LocalBridgeIfNeeded {
    if (-not (Test-Path -LiteralPath $LocalBridgePs1 -PathType Leaf)) {
        return
    }
    $cfg = Read-ThoughtConfigNormalized
    if ($null -ne $cfg -and -not $cfg.enabled) {
        Stop-LocalBridge
        return
    }
    if (Test-NamedMutexLocked -MutexName $BridgeMutexName) {
        $sameVer = $false
        if (Test-Path -LiteralPath $BridgeEndpointFile -PathType Leaf) {
            try {
                $ep = ([IO.File]::ReadAllText($BridgeEndpointFile, [Text.Encoding]::UTF8)) | ConvertFrom-Json
                if ($null -ne $ep -and $null -ne $ep.PSObject.Properties['version'] -and [string]$ep.version -eq $GuardRuntimeVersion) {
                    $sameVer = $true
                }
            } catch {}
        }
        if ($sameVer) { return }
        Stop-LocalBridge
    }
    if (Test-Path -LiteralPath $BridgeStopSignalFile -PathType Leaf) {
        Remove-Item -LiteralPath $BridgeStopSignalFile -Force -ErrorAction SilentlyContinue
    }
    $ev = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $BridgeStopEventName)
    try {
        [void]$ev.Reset()
    } finally {
        $ev.Dispose()
    }
    $p = $null
    try {
        $p = Start-Process -FilePath $PowerShellExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$LocalBridgePs1`"") -WorkingDirectory $ToolDir -WindowStyle Hidden -PassThru
    } finally {
        if ($null -ne $p) { $p.Dispose() }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 5000) {
        if ((Test-NamedMutexLocked -MutexName $BridgeMutexName) -and (Test-Path -LiteralPath $BridgeEndpointFile -PathType Leaf)) {
            return
        }
        Start-Sleep -Milliseconds 120
    }
    throw "本地直连翻译桥启动未在 5 秒内就绪，请检查日志: $LogPath"
}

function Stop-LocalBridge {
    [IO.File]::WriteAllText($BridgeStopSignalFile, 'stop', [Text.Encoding]::ASCII)
    $ev = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $BridgeStopEventName)
    try {
        [void]$ev.Set()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 7000) {
            if (-not (Test-NamedMutexLocked -MutexName $BridgeMutexName)) {
                return
            }
            Start-Sleep -Milliseconds 120
        }
        # Fallback kill of lingering local-bridge.ps1 process owned by this ToolDir
        try {
            $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue)
            foreach ($pr in $procs) {
                $cmd = [string]$pr.CommandLine
                if (-not [string]::IsNullOrWhiteSpace($cmd) -and $cmd.IndexOf($LocalBridgePs1, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    Stop-Process -Id ([int]$pr.ProcessId) -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {}
        $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw2.ElapsedMilliseconds -lt 2500) {
            if (-not (Test-NamedMutexLocked -MutexName $BridgeMutexName)) {
                return
            }
            Start-Sleep -Milliseconds 100
        }
        throw "等待本地直连翻译桥退出超时。"
    } finally {
        $ev.Dispose()
    }
}

function Clear-WatchStopSignals {
    if (Test-Path -LiteralPath $StopSignalFile -PathType Leaf) {
        Remove-Item -LiteralPath $StopSignalFile -Force -ErrorAction SilentlyContinue
    }
    $ev = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $WatchStopEventName)
    try {
        [void]$ev.Reset()
    } finally {
        $ev.Dispose()
    }
}

function Start-WatchBackgroundIfNeeded {
    if (Test-Path -LiteralPath $GuardDisabledFlag -PathType Leaf) {
        return
    }
    if (Test-NamedMutexLocked -MutexName $WatchMutexName) {
        $sameWatchVer = $false
        if (Test-Path -LiteralPath $WatchEndpointFile -PathType Leaf) {
            try {
                $wep = ([IO.File]::ReadAllText($WatchEndpointFile, [Text.Encoding]::UTF8)) | ConvertFrom-Json
                if ($null -ne $wep -and $null -ne $wep.PSObject.Properties['version'] -and [string]$wep.version -eq $GuardRuntimeVersion) {
                    $sameWatchVer = $true
                }
            } catch {}
        }
        if ($sameWatchVer) { return }
        Stop-WatchBackground
    }
    Clear-WatchStopSignals
    if (Test-Path -LiteralPath $LaunchVbsPath -PathType Leaf) {
        $p = $null
        try {
            $p = Start-Process -FilePath $WscriptPath -ArgumentList @("`"$LaunchVbsPath`"", '-Watch') -WorkingDirectory $ToolDir -WindowStyle Hidden -PassThru
        } finally {
            if ($null -ne $p) { $p.Dispose() }
        }
    }
}

function Stop-WatchBackground {
    [IO.File]::WriteAllText($StopSignalFile, 'stop', [Text.Encoding]::ASCII)
    $ev = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $WatchStopEventName)
    try {
        [void]$ev.Set()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 10000) {
            if (-not (Test-NamedMutexLocked -MutexName $WatchMutexName)) {
                return
            }
            Start-Sleep -Milliseconds 150
        }
        throw "等待后台自动汉化守护退出超时 (10 秒)。"
    } finally {
        $ev.Dispose()
    }
}

function Invoke-WatchLoop {
    $watchMutex = New-Object System.Threading.Mutex($false, $WatchMutexName)
    $ownsWatch = $false
    $publishedWatch = $false
    $stopEvent = $null
    try {
        try {
            $ownsWatch = $watchMutex.WaitOne(0)
        } catch [System.Threading.AbandonedMutexException] {
            $ownsWatch = $true
        }
        if (-not $ownsWatch) {
            return
        }

        $stopEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $WatchStopEventName)
        if (Test-WatchCancellationRequested -CancelEvent $stopEvent) {
            return
        }

        $wMeta = ([ordered]@{
            pid        = $PID
            version    = $GuardRuntimeVersion
            startedUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Compress)
        [IO.File]::WriteAllText($WatchEndpointFile, $wMeta, [Text.Encoding]::UTF8)
        $publishedWatch = $true

        $agExe = Resolve-AntigravityExe
        Write-LauncherLog -Scope 'WatchGuard' -Message "后台自动汉化守护已启动 (v$GuardRuntimeVersion, PID: $PID)。"

        $verifiedPort = 0
        $verifiedHansPid = 0
        $verifiedHansTicks = [int64]0
        $verifiedOwnerPid = 0
        $verifiedOwnerTicks = [int64]0
        $reverifySw = [System.Diagnostics.Stopwatch]::StartNew()

        $nonAgBackoffMap = @{}

        # Perform immediate initial check before first 3s sleep
        $firstIteration = $true
        while ($true) {
            if (-not $firstIteration) {
                if ($stopEvent.WaitOne(3000)) { break }
            }
            $firstIteration = $false

            if (Test-WatchCancellationRequested -CancelEvent $stopEvent) {
                break
            }

            try {
                if (Test-NamedMutexLocked -MutexName $UpdaterMutexName) {
                    continue
                }

                Start-LocalBridgeIfNeeded

                $candPorts = @(Get-CdpCandidatePorts)
                $ipProps = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
                $listeners = $ipProps.GetActiveTcpListeners()
                $loopbackListening = New-Object 'System.Collections.Generic.HashSet[int]'
                foreach ($ep in $listeners) {
                    if ([System.Net.IPAddress]::IsLoopback($ep.Address)) {
                        [void]$loopbackListening.Add([int]$ep.Port)
                    }
                }

                $activePort = 0
                foreach ($cp in $candPorts) {
                    if (-not $loopbackListening.Contains([int]$cp)) { continue }
                    if ($nonAgBackoffMap.ContainsKey([int]$cp) -and $nonAgBackoffMap[[int]$cp].Elapsed.TotalSeconds -lt 10) {
                        continue
                    }
                    $activePort = [int]$cp
                    break
                }

                if ($activePort -eq 0) {
                    $verifiedPort = 0
                    $verifiedHansPid = 0
                    continue
                }

                # Pure .NET fast-path valid up to 30s between full OwningProcess re-verifications
                if ($activePort -eq $verifiedPort -and $verifiedHansPid -gt 0 -and $reverifySw.Elapsed.TotalSeconds -lt 30) {
                    $pairStillValid = $false
                    $hansProc = $null
                    $ownerProc = $null
                    try {
                        $hansProc = [System.Diagnostics.Process]::GetProcessById($verifiedHansPid)
                        $ownerProc = [System.Diagnostics.Process]::GetProcessById($verifiedOwnerPid)
                        if (-not $hansProc.HasExited -and
                            $hansProc.ProcessName -eq 'antigravity-hans-windows-amd64' -and
                            $hansProc.StartTime.ToUniversalTime().Ticks -eq $verifiedHansTicks -and
                            -not $ownerProc.HasExited -and
                            $ownerProc.ProcessName -eq 'Antigravity' -and
                            $ownerProc.StartTime.ToUniversalTime().Ticks -eq $verifiedOwnerTicks) {
                            $pairStillValid = $true
                        }
                    } catch {
                        $pairStillValid = $false
                    } finally {
                        if ($null -ne $hansProc) { $hansProc.Dispose() }
                        if ($null -ne $ownerProc) { $ownerProc.Dispose() }
                    }

                    if ($pairStillValid) {
                        $hasEst = $false
                        $tcpConns = $ipProps.GetActiveTcpConnections()
                        foreach ($tc in $tcpConns) {
                            if ($tc.State -eq [System.Net.NetworkInformation.TcpState]::Established -and
                                $tc.RemoteEndPoint.Port -eq $activePort -and
                                [System.Net.IPAddress]::IsLoopback($tc.RemoteEndPoint.Address)) {
                                $hasEst = $true
                                break
                            }
                        }
                        if ($hasEst) {
                            continue
                        }
                    }
                }

                if (-not $agExe -or -not (Test-Path -LiteralPath $agExe -PathType Leaf)) {
                    $agExe = Resolve-AntigravityExe
                }

                $cdpCheck = Get-VerifiedAntigravityCdpEndpoint -ExpectedExePath $agExe -Ports @($activePort)
                if ($null -eq $cdpCheck) {
                    $nonAgBackoffMap[$activePort] = [System.Diagnostics.Stopwatch]::StartNew()
                    continue
                }
                if ($nonAgBackoffMap.ContainsKey($cdpCheck.Port)) {
                    $nonAgBackoffMap.Remove($cdpCheck.Port)
                }

                $res = Ensure-HansAttached -ExpectedAntigravityExe $agExe -WaitPortSeconds 5 -Scope 'WatchGuard' -CancelEvent $stopEvent
                if ($res.Attached) {
                    $verifiedPort = $res.Port
                    $verifiedHansPid = $res.HansPid
                    $verifiedHansTicks = $res.HansStartTicks
                    $verifiedOwnerPid = $res.OwnerPid
                    $verifiedOwnerTicks = $res.OwnerStartTicks
                    $reverifySw.Restart()
                }
            } catch {
                Write-LauncherLog -Scope 'WatchGuard' -Message "巡检异常: $($_.Exception.Message)"
            }
        }

        Write-LauncherLog -Scope 'WatchGuard' -Message "后台自动汉化守护已正常退出 (PID: $PID)。"
    } finally {
        if ($ownsWatch -and $publishedWatch -and (Test-Path -LiteralPath $WatchEndpointFile -PathType Leaf)) {
            try {
                $curW = ([IO.File]::ReadAllText($WatchEndpointFile, [Text.Encoding]::UTF8)) | ConvertFrom-Json
                if ($null -ne $curW -and [int]$curW.pid -eq $PID) {
                    Remove-Item -LiteralPath $WatchEndpointFile -Force -ErrorAction SilentlyContinue
                }
            } catch {}
        }
        if ($null -ne $stopEvent) {
            $stopEvent.Dispose()
        }
        if ($ownsWatch) {
            try { $watchMutex.ReleaseMutex() } catch {}
        }
        $watchMutex.Dispose()
    }
}

function Show-CurrentStatus {
    $agExe = Resolve-AntigravityExe
    $mainProc = Get-AntigravityMainProcess -ExpectedExePath $agExe
    $cdpEp = Get-VerifiedAntigravityCdpEndpoint -ExpectedExePath $agExe
    $attachedInfo = if ($null -ne $cdpEp) { Get-AttachedHansInfo -Port $cdpEp.Port } else { $null }
    $watchAlive = Test-NamedMutexLocked -MutexName $WatchMutexName
    $regEnabled = Test-StartupGuardRegistered
    $bridgePortAlive = Get-ActiveLocalBridgePort
    $thoughtDesc = Get-ThoughtTranslationSummary

    Write-Host "================ Antigravity 汉化状态诊断 ================"
    Write-Host ("1. 客户端安装路径   : {0}" -f ($(if ($agExe) { $agExe } else { '未找到' })))
    Write-Host ("2. 主界面进程状态   : {0}" -f ($(if ($null -ne $mainProc) { "运行中 (PID: $($mainProc.ProcessId), 状态: $($mainProc.State))" } else { '未运行' })))
    Write-Host ("3. 浏览器 CDP 端口  : {0}" -f ($(if ($null -ne $cdpEp) { "127.0.0.1:$($cdpEp.Port) (宿主 PID: $($cdpEp.OwnerPid))" } else { '未就绪' })))
    Write-Host ("4. 汉化注入监视器   : {0}" -f ($(if ($null -ne $attachedInfo) { "检测到活动连接 (PID: $($attachedInfo.Id))" } else { '未连接' })))
    Write-Host ("5. 后台自动汉化守护 : {0} | 登录自启: {1}" -f ($(if ($watchAlive) { '运行中 (约每 3 秒巡检)' } else { '未运行' }), $(if ($regEnabled) { '已开启' } else { '已关闭' })))
    Write-Host ("6. 本地直连翻译桥   : {0}" -f ($(if ($bridgePortAlive -gt 0) { "运行中 (127.0.0.1:$bridgePortAlive, 绕开海外代理防429)" } else { '未运行' })))
    Write-Host ("7. 思考与动作汉化   : {0}" -f $thoughtDesc)
    Write-Host ("8. 运行日志路径     : {0}" -f $LogPath)
    if ($null -ne $mainProc -and $null -eq $cdpEp) {
        Write-Host "[提示] 当前运行中的 Antigravity (PID: $($mainProc.ProcessId)) 未开启 CDP 调试端口。"
        Write-Host "       Antigravity 2.33+ 已将 CDP 改为显式启动开关，请退出当前窗口后通过桌面「Antigravity 中文」快捷方式启动"
        Write-Host "       (或在 Cockpit / 启动参数中加入: --remote-debugging-port=0 --remote-debugging-address=127.0.0.1)。"
    }
    Write-Host "=========================================================="
}

function Read-SecretLineTrimmed {
    param([string]$PromptText)
    $sec = Read-Host $PromptText -AsSecureString
    if ($null -eq $sec -or $sec.Length -eq 0) { return '' }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try {
        return ([Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)).Trim()
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Invoke-ThoughtTranslationMenu {
    param([string]$AntigravityExe)
    Write-Host ""
    Write-Host "---------- 思考框与动作标签实时翻译设置 ----------"
    Write-Host ("当前状态: {0}" -f (Get-ThoughtTranslationSummary))
    Write-Host "  [1] 免 Key 本地免代理直连 + 多段打包 (默认推荐，走自家宽带直连腾讯 TranSmart，彻底防代理 429)"
    Write-Host "  [2] 配置智谱清言官方免费大模型 GLM-4-Flash API Key (国内直连永久免费、高并发)"
    Write-Host "  [3] 配置硅基流动 SiliconFlow (免费 Qwen2.5-7B) / DeepSeek / 自定义 OpenAI 兼容接口"
    Write-Host "  [4] 配置 Google AI Studio 独立 GEMINI_API_KEY (直连官方 gemini-3.5-flash-lite)"
    Write-Host "  [5] 连接本机离线翻译模型 (Ollama，默认 http://127.0.0.1:11434/v1/chat/completions + qwen2.5:3b)"
    Write-Host "  [6] 关闭思考框实时翻译 (仅保留基础界面汉化)"
    Write-Host "  [B] 返回"
    $sub = (Read-Host "输入序号").Trim().ToUpperInvariant()

    # Collect user intent outside lock so interactive prompt never holds LauncherMutex
    $intent = $null
    $pendingKey = ''
    $pendingUrl = ''
    $pendingModel = ''
    switch ($sub) {
        '1' {
            $intent = 'free-direct'
        }
        '2' {
            $pendingKey = Read-SecretLineTrimmed -PromptText "粘贴智谱 BigModel API Key (隐藏回显；输入 CLEAR 清空已有 Key)"
            if ($pendingKey.ToUpperInvariant() -eq 'CLEAR') {
                $intent = 'clear-llm'
            } elseif (-not [string]::IsNullOrWhiteSpace($pendingKey)) {
                $intent = 'set-zhipu'
            } else {
                Write-Host "[取消] 未输入内容，保持原配置不变。"
                return
            }
        }
        '3' {
            $pendingKey = Read-SecretLineTrimmed -PromptText "粘贴 SiliconFlow / DeepSeek / OpenAI兼容 API Key (隐藏回显；输入 CLEAR 清空)"
            if ($pendingKey.ToUpperInvariant() -eq 'CLEAR') {
                $intent = 'clear-llm'
            } elseif (-not [string]::IsNullOrWhiteSpace($pendingKey)) {
                $inUrl = (Read-Host "接口地址 (直接回车默认使用硅基流动 https://api.siliconflow.cn/v1/chat/completions)").Trim()
                $inModel = (Read-Host "模型名称 (直接回车默认使用硅基流动免费模型 Qwen/Qwen2.5-7B-Instruct)").Trim()
                $pendingUrl = if ([string]::IsNullOrWhiteSpace($inUrl)) { 'https://api.siliconflow.cn/v1/chat/completions' } else { $inUrl }
                $uCheck = $null
                if (-not [Uri]::TryCreate($pendingUrl, [UriKind]::Absolute, [ref]$uCheck) -or
                    ($uCheck.Scheme -ne 'https' -and -not ($uCheck.Scheme -eq 'http' -and $uCheck.Host -in @('127.0.0.1', 'localhost')))) {
                    throw "自定义大模型地址必须使用 https:// (仅本机回环 127.0.0.1/localhost 允许 http://): $pendingUrl"
                }
                $pendingModel = if ([string]::IsNullOrWhiteSpace($inModel)) { 'Qwen/Qwen2.5-7B-Instruct' } else { $inModel }
                $intent = 'set-openai-compat'
            } else {
                Write-Host "[取消] 未输入内容，保持原配置不变。"
                return
            }
        }
        '4' {
            $pendingKey = Read-SecretLineTrimmed -PromptText "粘贴独立 Google AI Studio GEMINI_API_KEY (隐藏回显；输入 CLEAR 清空已有 Key)"
            if ($pendingKey.ToUpperInvariant() -eq 'CLEAR') {
                $intent = 'clear-gemini'
            } elseif (-not [string]::IsNullOrWhiteSpace($pendingKey)) {
                $intent = 'set-gemini'
            } else {
                Write-Host "[取消] 未输入内容，保持原配置不变。"
                return
            }
        }
        '5' {
            $inLocalUrl = (Read-Host "本机模型地址 (直接回车默认 http://127.0.0.1:11434/v1/chat/completions)").Trim()
            $inLocalModel = (Read-Host "本机模型名称 (直接回车默认 qwen2.5:3b)").Trim()
            $pendingUrl = if ([string]::IsNullOrWhiteSpace($inLocalUrl)) { 'http://127.0.0.1:11434/v1/chat/completions' } else { $inLocalUrl }
            $uLocal = $null
            if (-not [Uri]::TryCreate($pendingUrl, [UriKind]::Absolute, [ref]$uLocal) -or
                -not (($uLocal.Scheme -in @('http', 'https')) -and ($uLocal.Host -in @('127.0.0.1', 'localhost')))) {
                throw "本机离线模型地址仅允许 127.0.0.1 或 localhost: $pendingUrl"
            }
            $pendingModel = if ([string]::IsNullOrWhiteSpace($inLocalModel)) { 'qwen2.5:3b' } else { $inLocalModel }
            $intent = 'set-local-llm'
        }
        '6' {
            $intent = 'disable'
        }
        default {
            return
        }
    }

    $lock = Enter-LauncherMutex -TimeoutMs 15000
    if ($null -eq $lock) {
        throw "获取汉化器操作锁超时，请稍后重试。"
    }
    try {
        $cfg = Read-ThoughtConfigNormalized
        if ($null -eq $cfg) {
            $cfg = [ordered]@{
                enabled      = $true
                provider     = 'auto'
                bridgePort   = 47831
                bridgeToken  = ''
                llmApiKey    = ''
                llmBaseUrl   = 'https://open.bigmodel.cn/api/paas/v4/chat/completions'
                llmModel     = 'glm-4-flash'
                geminiApiKey = ''
                geminiModel  = 'gemini-3.5-flash-lite'
            }
        }
        switch ($intent) {
            'free-direct' {
                $cfg['enabled'] = $true
                $cfg['provider'] = 'free-direct'
                Write-Host "[已保存] 已切换为免 Key 本地免代理直连 + 多段打包模式。"
            }
            'clear-llm' {
                $cfg['llmApiKey'] = ''
                if ($cfg['provider'] -in @('zhipu', 'openai-compat')) { $cfg['provider'] = 'auto' }
                Write-Host "[已保存] 已清空国内大模型 API Key，自动回退至免 Key 本地直连模式。"
            }
            'set-zhipu' {
                $cfg['enabled'] = $true
                $cfg['provider'] = 'zhipu'
                $cfg['llmApiKey'] = $pendingKey
                $cfg['llmBaseUrl'] = 'https://open.bigmodel.cn/api/paas/v4/chat/completions'
                $cfg['llmModel'] = 'glm-4-flash'
                Write-Host "[已保存] 已启用智谱官方免费大模型 glm-4-flash (国内免代理直连，异常自动降级本地直连桥)。"
            }
            'set-openai-compat' {
                $cfg['enabled'] = $true
                $cfg['provider'] = 'openai-compat'
                $cfg['llmApiKey'] = $pendingKey
                $cfg['llmBaseUrl'] = $pendingUrl
                $cfg['llmModel'] = $pendingModel
                Write-Host "[已保存] 已启用独立大模型接口 ($pendingModel，异常自动降级本地直连桥)。"
            }
            'clear-gemini' {
                $cfg['geminiApiKey'] = ''
                if ($cfg['provider'] -eq 'gemini') { $cfg['provider'] = 'auto' }
                Write-Host "[已保存] 已清空 GEMINI_API_KEY，自动回退至免 Key 本地直连模式。"
            }
            'set-gemini' {
                $cfg['enabled'] = $true
                $cfg['provider'] = 'gemini'
                $cfg['geminiApiKey'] = $pendingKey
                $cfg['geminiModel'] = 'gemini-3.5-flash-lite'
                Write-Host "[已保存] 已配置官方 GEMINI_API_KEY (模型: gemini-3.5-flash-lite，失败自动降级本地直连桥)。"
            }
            'set-local-llm' {
                $cfg['enabled'] = $true
                $cfg['provider'] = 'local-llm'
                $cfg['llmBaseUrl'] = $pendingUrl
                $cfg['llmModel'] = $pendingModel
                Write-Host "[已保存] 已启用本机离线翻译模型 ($pendingModel @ $pendingUrl，异常自动降级本地直连桥)。"
            }
            'disable' {
                $cfg['enabled'] = $false
                Write-Host "[已保存] 已关闭思考框与动作标签实时翻译。"
            }
        }
        Save-ThoughtConfigNormalized -ConfigMap $cfg
        $shouldRunBridge = [bool]$cfg['enabled']
    } finally {
        Exit-LauncherMutex -Mutex $lock
    }

    if ($shouldRunBridge) {
        Start-LocalBridgeIfNeeded
    } else {
        Stop-LocalBridge
    }

    $lock2 = Enter-LauncherMutex -TimeoutMs 15000
    if ($null -eq $lock2) {
        throw "获取汉化器操作锁超时，请稍后重试。"
    }
    try {
        $ov = Ensure-OverlayReady -ForceRebuild -CallerHoldsLauncherMutex -Scope 'MenuConfig'
        if (-not $ov.Available) {
            Write-Warning "合成 antigravity-hans-overlay.js 未成功，请检查日志: $LogPath"
            return
        }
        if ($null -ne (Get-AntigravityMainProcess -ExpectedExePath $AntigravityExe)) {
            $r = Ensure-HansAttached -ExpectedAntigravityExe $AntigravityExe -WaitPortSeconds 15 -Scope 'MenuConfig' -CallerHoldsLauncherMutex -ForceReattach -SkipOverlayBuild
            if ($r.Attached) {
                Write-Host "[生效] 已热重载当前窗口汉化监视器 (端口 $($r.Port), PID $($r.HansPid))！"
            }
        } else {
            Write-Host "[生效] 外部汉化脚本已更新，下次打开 Antigravity 时自动生效。"
        }
    } finally {
        Exit-LauncherMutex -Mutex $lock2
    }
}

# --- Top-Level Execution with Fatal Logging ---
try {
    if ($DisableAutoGuard) {
        Set-StartupGuardRegistration -Enable $false
        Stop-WatchBackground
        Stop-LocalBridge
        Stop-HansMonitorsSynchronized
        Write-Host "[完成] 已关闭后台自动守护、本地翻译桥并停止当前汉化监视器。"
        return
    }

    if ($StopAll) {
        Stop-WatchBackground
        Stop-LocalBridge
        Stop-HansMonitorsSynchronized
        Write-Host "[完成] 已停止后台守护、本地翻译桥与汉化监视器。"
        return
    }

    if ($EnableAutoGuard) {
        Set-StartupGuardRegistration -Enable $true
        Start-LocalBridgeIfNeeded
        Start-WatchBackgroundIfNeeded
        Write-Host "[完成] 已开启自动汉化后台守护、本地免代理翻译桥与登录自启。"
        return
    }

    if ($Watch) {
        Invoke-WatchLoop
        return
    }

    $AntigravityExe = Resolve-AntigravityExe

    if ($SyncShortcuts) {
        Sync-LauncherShortcuts -AntigravityExe $AntigravityExe
        Write-Host "[完成] 已同步桌面与开始菜单「Antigravity 中文」快捷方式。"
        return
    }

    if ($Status) {
        Show-CurrentStatus
        return
    }

    if ($RebuildOverlay) {
        Start-LocalBridgeIfNeeded
        Start-WatchBackgroundIfNeeded
        $lock = Enter-LauncherMutex -TimeoutMs 15000
        if ($null -eq $lock) {
            throw "获取汉化器操作锁超时，无法重建外部汉化脚本。"
        }
        try {
            $ov = Ensure-OverlayReady -ForceRebuild -CallerHoldsLauncherMutex -Scope 'RebuildOverlay'
            if (-not $ov.Available) {
                throw "合成 antigravity-hans-overlay.js 失败。"
            }
            $mainProc = Get-AntigravityMainProcess -ExpectedExePath $AntigravityExe
            if ($null -ne $mainProc) {
                if ($mainProc.State -eq 'ConfirmedUi' -and (Get-ProcessRemoteDebuggingSwitchState -ProcessId ([int]$mainProc.ProcessId)) -eq 'MissingSwitch') {
                    Write-Host "[完成] 已重建外部汉化脚本。当前运行中的 Antigravity (PID: $($mainProc.ProcessId)) 未携带 --remote-debugging-port 启动（Antigravity 2.33+ 需带调试端口启动才能热注入）；请关闭后通过「Antigravity 中文」重启即可生效。"
                } else {
                    $res = Ensure-HansAttached -ExpectedAntigravityExe $AntigravityExe -WaitPortSeconds 15 -Scope 'RebuildOverlay' -CallerHoldsLauncherMutex -ForceReattach -SkipOverlayBuild
                    if (-not $res.Attached) {
                        exit 2
                    }
                    Write-Host "[完成] 已重建外部汉化脚本并热重载至运行中窗口 (端口 $($res.Port), PID $($res.HansPid))。"
                }
            } else {
                Write-Host "[完成] 已重建 antigravity-hans-overlay.js。"
            }
        } finally {
            Exit-LauncherMutex -Mutex $lock
        }
        return
    }

    if ($InteractiveMenu) {
        Show-CurrentStatus
        Write-Host ""
        Write-Host "请选择操作:"
        Write-Host "  [1] 立即对当前窗口挂载汉化并开启自动守护 (推荐)"
        Write-Host "  [2] 停止当前汉化监视器并关闭开机自动守护"
        Write-Host "  [3] 重新修复桌面与开始菜单快捷方式"
        Write-Host "  [4] 配置思考框实时翻译源 (免Key直连桥 / 智谱免费GLM-4 / SiliconFlow / Gemini)"
        Write-Host "  [Q] 退出"
        $choice = (Read-Host "输入序号").Trim().ToUpperInvariant()
        switch ($choice) {
            '1' {
                Set-StartupGuardRegistration -Enable $true
                Start-LocalBridgeIfNeeded
                Start-WatchBackgroundIfNeeded
                $menuMain = Get-AntigravityMainProcess -ExpectedExePath $AntigravityExe
                if ($null -ne $menuMain) {
                    if ($menuMain.State -eq 'ConfirmedUi' -and (Get-ProcessRemoteDebuggingSwitchState -ProcessId ([int]$menuMain.ProcessId)) -eq 'MissingSwitch') {
                        Write-Host "[提示] 自动守护已开启，但当前 Antigravity (PID: $($menuMain.ProcessId)) 启动时未携带 --remote-debugging-port（Antigravity 2.33+ 默认关闭 CDP 端口）。"
                        Write-Host "       请退出当前 Antigravity 后，点击桌面「Antigravity 中文」快捷方式启动即可自动汉化。"
                    } else {
                        $r = Ensure-HansAttached -ExpectedAntigravityExe $AntigravityExe -WaitPortSeconds 15 -Scope 'Menu'
                        Write-Host ($(if ($r.Attached) { "[成功] 已建立汉化连接 (端口 $($r.Port), PID $($r.HansPid))。" } else { "[提示] 暂未检测到就绪端口，守护进程将在窗口就绪后自动挂载。" }))
                    }
                } else {
                    Write-Host "[成功] 自动守护已就绪，点击「Antigravity 中文」打开时将自动挂载汉化。"
                }
            }
            '2' {
                Set-StartupGuardRegistration -Enable $false
                Stop-WatchBackground
                Stop-LocalBridge
                Stop-HansMonitorsSynchronized
                Write-Host "[完成] 已停止汉化监视器、本地翻译桥并取消自动守护。"
            }
            '3' {
                Sync-LauncherShortcuts -AntigravityExe $AntigravityExe
                Write-Host "[完成] 快捷方式已修复。"
            }
            '4' {
                Invoke-ThoughtTranslationMenu -AntigravityExe $AntigravityExe
            }
            default { }
        }
        return
    }

    if ($AttachOnly) {
        Start-LocalBridgeIfNeeded
        Start-WatchBackgroundIfNeeded
        $mainProc = Get-AntigravityMainProcess -ExpectedExePath $AntigravityExe
        if ($null -ne $mainProc) {
            if ($mainProc.State -eq 'ConfirmedUi' -and (Get-ProcessRemoteDebuggingSwitchState -ProcessId ([int]$mainProc.ProcessId)) -eq 'MissingSwitch') {
                Write-Host "[提示] 当前运行中的 Antigravity (PID: $($mainProc.ProcessId)) 未携带 --remote-debugging-port 启动，无法热挂载；请通过「Antigravity 中文」重启。"
                exit 2
            }
            $res = Ensure-HansAttached -ExpectedAntigravityExe $AntigravityExe -WaitPortSeconds 15 -Scope 'AttachOnly'
            if (-not $res.Attached) {
                exit 2
            }
        }
        return
    }

    # --- Default Mode: Clicked "Antigravity 中文" Shortcut ---
    if (-not $AntigravityExe -or -not (Test-Path -LiteralPath $AntigravityExe -PathType Leaf)) {
        throw "未找到 Antigravity.exe 安装路径，请确认 Antigravity 已正确安装。"
    }

    Start-LocalBridgeIfNeeded
    Start-WatchBackgroundIfNeeded

    # Prompt outside mutex if Antigravity 2.33+ is already running without --remote-debugging-port
    $restartApprovedPid = 0
    $restartApprovedTicks = [int64]0
    $preExisting = Get-AntigravityMainProcess -ExpectedExePath $AntigravityExe
    if ($null -ne $preExisting -and $preExisting.State -eq 'ConfirmedUi' -and (Get-ProcessRemoteDebuggingSwitchState -ProcessId ([int]$preExisting.ProcessId)) -eq 'MissingSwitch') {
        $capturedPid = [int]$preExisting.ProcessId
        $capturedTicks = Get-ProcessStartTicksSafe -ProcessId $capturedPid -ExpectedExePath $AntigravityExe
        $wshPopup = New-Object -ComObject WScript.Shell
        $msg = "检测到 Antigravity 已在运行，但当前窗口未开启 CDP 调试端口（Antigravity 2.33+ 需携带 --remote-debugging-port 才能动态汉化）。`r`n`r`n是否温和关闭当前窗口，并立即以「中文调试模式」重新启动？`r`n（选择「否」将仅切换回原窗口，不做关闭）"
        $ans = $wshPopup.Popup($msg, 30, 'Antigravity 中文启动器', 36)
        if ($ans -eq 6 -and $capturedTicks -gt 0) {
            $restartApprovedPid = $capturedPid
            $restartApprovedTicks = $capturedTicks
        } else {
            Write-LauncherLog -Scope 'Launcher' -Message "用户取消重启无 CDP 窗口，仅激活原窗口 (PID: $capturedPid)。"
            if ($capturedTicks -gt 0 -and (Get-ProcessStartTicksSafe -ProcessId $capturedPid -ExpectedExePath $AntigravityExe) -eq $capturedTicks) {
                Set-ProcessWindowForeground -PreferredPid $capturedPid
            }
            return
        }
    }

    $launchLock = Enter-LauncherMutex -TimeoutMs 15000
    if ($null -eq $launchLock) {
        throw "另一个启动或更新流程正在进行中，获取操作锁超时。"
    }
    try {
        if ($restartApprovedPid -gt 0 -and $restartApprovedTicks -gt 0) {
            $curTicks = Get-ProcessStartTicksSafe -ProcessId $restartApprovedPid -ExpectedExePath $AntigravityExe
            if ($curTicks -eq $restartApprovedTicks) {
                Write-LauncherLog -Scope 'Launcher' -Message "用户同意温和重启未开启 CDP 的 Antigravity (PID: $restartApprovedPid)。"
                $quitOk = Request-GracefulAntigravityQuit -PreferredPid $restartApprovedPid -ExpectedStartTicks $restartApprovedTicks -ExpectedExePath $AntigravityExe -TimeoutSeconds 10
                if (-not $quitOk) {
                    Write-LauncherLog -Scope 'Launcher' -Message "温和退出等待超时，中止重启以避免丢失未保存内容。"
                    $wshWarn = New-Object -ComObject WScript.Shell
                    [void]$wshWarn.Popup("原 Antigravity 窗口未在 10 秒内退出，请手动保存并完全退出后，再点击「Antigravity 中文」启动。", 15, 'Antigravity 中文启动器', 48)
                    return
                }
            }
        }

        $existingMain = Get-AntigravityMainProcess -ExpectedExePath $AntigravityExe
        if ($null -eq $existingMain) {
            $launchArgs = @('--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1')
            Write-LauncherLog -Scope 'Launcher' -Message "未检测到主界面进程，正在以随机回环调试端口 (--remote-debugging-port=0) 启动: $AntigravityExe"
            $startedApp = $null
            try {
                $startedApp = Start-Process -FilePath $AntigravityExe -ArgumentList $launchArgs -WorkingDirectory ([IO.Path]::GetDirectoryName($AntigravityExe)) -PassThru
                Save-LauncherSpawnRecord -ProcessObj $startedApp
            } finally {
                if ($null -ne $startedApp) { $startedApp.Dispose() }
            }
        } else {
            Write-LauncherLog -Scope 'Launcher' -Message "检测到已运行主界面进程 (PID: $($existingMain.ProcessId), 状态: $($existingMain.State))，激活窗口并核验汉化连接。"
            Set-ProcessWindowForeground -PreferredPid ([int]$existingMain.ProcessId)
            if ($existingMain.State -eq 'ConfirmedUi' -and (Get-ProcessRemoteDebuggingSwitchState -ProcessId ([int]$existingMain.ProcessId)) -eq 'MissingSwitch') {
                return
            }
        }

        $attachRes = Ensure-HansAttached -ExpectedAntigravityExe $AntigravityExe -WaitPortSeconds 30 -Scope 'Launcher' -CallerHoldsLauncherMutex
        if (-not $attachRes.Attached) {
            exit 3
        }
    } finally {
        Exit-LauncherMutex -Mutex $launchLock
    }
} catch {
    Write-LauncherLog -Scope 'Fatal' -Message $_.Exception.Message
    throw
}
