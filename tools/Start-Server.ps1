param([string]$StartupLog, [int]$StatsProcessId, [switch]$StatsOnce)

$ErrorActionPreference = 'Stop'
$serverRoot = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $serverRoot 'bedrock_server.exe'

function Set-ConsoleTile([switch]$Right, [switch]$Bottom) {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -Name ConsoleLayout -Namespace Lunos -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetWindowPos(System.IntPtr window, System.IntPtr after,
    int x, int y, int width, int height, uint flags);
"@
        $window = [Lunos.ConsoleLayout]::GetConsoleWindow()
        if ($window -eq [IntPtr]::Zero) { return }
        $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $leftWidth = [int][Math]::Floor($area.Width / 2)
        $height = [int][Math]::Floor($area.Height / 2)
        $x = $area.Left
        $width = $leftWidth
        if ($Right) {
            $x += $leftWidth
            $width = $area.Width - $leftWidth
        }
        $y = $area.Top
        if ($Bottom) { $y += $height }
        [void][Lunos.ConsoleLayout]::SetWindowPos($window, [IntPtr]::Zero, $x, $y, $width, $height, 0x0014)
    } catch {
        Write-Host '  Window tiling unavailable.' -ForegroundColor Yellow
    }
}

function Get-SessionPlaytime([string]$LogPath, [datetime]$Until) {
    $peak = 0
    $players = @{}
    $playtime = @{}
    $lastSeen = @{}
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $eventPattern = '^\[(?<time>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}:\d{3}) INFO\]\s+Player (?<action>connected|disconnected): (?<player>.*?), xuid:'
    foreach ($entry in Select-String -LiteralPath $LogPath -Pattern $eventPattern) {
        $event = $entry.Matches[0]
        $player = $event.Groups['player'].Value
        $eventTime = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($event.Groups['time'].Value, 'yyyy-MM-dd HH:mm:ss:fff', $culture, [Globalization.DateTimeStyles]::None, [ref]$eventTime) -or
            $eventTime -gt $until) { continue }

        if ($event.Groups['action'].Value -eq 'connected') {
            if (-not $playtime.ContainsKey($player)) { $playtime[$player] = [TimeSpan]::Zero }
            if (-not $players.ContainsKey($player)) { $players[$player] = $eventTime }
            $peak = [Math]::Max($peak, $players.Count)
        } elseif ($players.ContainsKey($player) -and $eventTime -ge $players[$player]) {
            $playtime[$player] += $eventTime - $players[$player]
            $lastSeen[$player] = $eventTime
            $players.Remove($player)
        }
    }
    foreach ($player in $players.Keys) {
        $playtime[$player] += $until - $players[$player]
        $lastSeen[$player] = $until
    }
    return @{ Online = $players; Playtime = $playtime; LastSeen = $lastSeen; Peak = $peak }
}

function Read-GlobalPlaytime([string]$Path) {
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $legacyHeader = "Player`tTotal playtime"
    $header = "$legacyHeader`tLast seen (local time)"
    $dateFormat = 'yyyy-MM-dd HH:mm:ss'
    $lastSeen = @{}
    $totals = @{}
    if (Test-Path -LiteralPath $Path) {
        $lines = [IO.File]::ReadAllLines($Path)
        if ($lines.Count -eq 0 -or $lines[0] -cnotin @($legacyHeader, $header)) {
            throw 'The global playtime file has an unexpected header.'
        }
        $columnCount = if ($lines[0] -ceq $header) { 3 } else { 2 }
        foreach ($line in ($lines | Select-Object -Skip 1)) {
            $columns = $line -split "`t", $columnCount
            $duration = [TimeSpan]::Zero
            if ($columns.Count -ne $columnCount -or !$columns[0] -or $totals.ContainsKey($columns[0]) -or
                ![TimeSpan]::TryParseExact($columns[1], 'c', $culture, [ref]$duration) -or $duration.Ticks -lt 0) {
                throw 'The global playtime file has an invalid player row.'
            }
            $totals[$columns[0]] = $duration
            if ($columnCount -eq 3 -and $columns[2] -ne 'Unknown') {
                $seenAt = [datetime]::MinValue
                if (![datetime]::TryParseExact($columns[2], $dateFormat, $culture, [Globalization.DateTimeStyles]::None, [ref]$seenAt)) {
                    throw 'The global playtime file has an invalid last-seen timestamp.'
                }
                $lastSeen[$columns[0]] = $seenAt
            }
        }
    }
    return @{ Playtime = $totals; LastSeen = $lastSeen; Header = $header; DateFormat = $dateFormat }
}

function Show-PlaytimeLeaderboard([string]$Title, [hashtable]$Playtime) {
    Write-Host "  $Title" -ForegroundColor Cyan
    if ($Playtime.Count -eq 0) {
        Write-Host '    No playtime recorded yet.' -ForegroundColor Gray
        return
    }

    $rank = 0
    $leaders = $Playtime.GetEnumerator() |
        Sort-Object @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key'; Ascending = $true }
    foreach ($leader in $leaders) {
        $rank++
        Write-Host ('  {0,3}. {1,3}d {2:hh}h {2:mm}m {2:ss}s  {3}' -f $rank, $leader.Value.Days, $leader.Value, $leader.Key)
    }
}

function Save-GlobalPlaytime([string]$Path, [hashtable]$Session) {
    $mutex = [Threading.Mutex]::new($false, 'Local\LunosToolboxGlobalPlaytime')
    $locked = $false
    $pending = "$Path.$([Guid]::NewGuid()).partial"
    try {
        try {
            $locked = $mutex.WaitOne([TimeSpan]::FromSeconds(10))
        } catch [Threading.AbandonedMutexException] {
            $locked = $true
        }
        if (!$locked) { throw 'Another session is saving playtime. The totals file is busy.' }

        $saved = Read-GlobalPlaytime $Path
        $totals = $saved.Playtime
        $lastSeen = $saved.LastSeen
        $culture = [Globalization.CultureInfo]::InvariantCulture
        foreach ($player in $Session.Playtime.Keys) {
            if (!$totals.ContainsKey($player)) { $totals[$player] = [TimeSpan]::Zero }
            $totals[$player] += $Session.Playtime[$player]
            $seenAt = $Session.LastSeen[$player]
            if ($seenAt -and (!$lastSeen.ContainsKey($player) -or $seenAt -gt $lastSeen[$player])) {
                $lastSeen[$player] = $seenAt
            }
        }

        $rows = $totals.GetEnumerator() |
            Sort-Object @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key'; Ascending = $true } |
            ForEach-Object {
                $seenAt = $lastSeen[$_.Key]
                $display = if ($seenAt) { $seenAt.ToString($saved.DateFormat, $culture) } else { 'Unknown' }
                "{0}`t{1}`t{2}" -f $_.Key, $_.Value.ToString('c', $culture), $display
            }
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        [IO.File]::WriteAllLines($pending, [string[]](@($saved.Header) + @($rows)), [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($pending, $Path, [NullString]::Value)
        } else {
            [IO.File]::Move($pending, $Path)
        }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
        if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending }
    }
}

if ($StatsProcessId) {
    $Host.UI.RawUI.WindowTitle = 'Lunos Toolbox | Live Stats Dashboard'
    if (-not $StatsOnce) { Set-ConsoleTile -Right }

    $server = Get-Process -Id $StatsProcessId -ErrorAction SilentlyContinue
    if (-not $server -or $server.Path -ne $exe) { exit }
    [void]$server.Handle
    $started = $server.StartTime
    # Keep the pre-session totals so the shutdown save cannot double-count this session.
    $previousPlaytime = $null
    $globalStatsError = 'The server stopped before the totals could be read.'
    $totalsFile = Join-Path $PSScriptRoot 'GlobalServerStats\Playtime.txt'
    try {
        $saved = Read-GlobalPlaytime $totalsFile
        $server.Refresh()
        if (!$server.HasExited) { $previousPlaytime = $saved.Playtime }
    } catch {
        $globalStatsError = $_.Exception.Message
    }
    . (Join-Path $PSScriptRoot 'Toolbox-Settings.ps1')
    $settings = Get-ToolboxSettings
    $destinations = [ordered]@{ 'Primary' = $settings.PrimaryBackup }
    if ($settings.SecondaryBackup) { $destinations['Secondary'] = $settings.SecondaryBackup }
    do {
        $server.Refresh()
        $ended = $server.HasExited
        $until = if ($ended) { $server.ExitTime } else { Get-Date }
        $session = Get-SessionPlaytime -LogPath $StartupLog -Until $until
        $players = $session.Online
        $playtime = $session.Playtime
        $peak = $session.Peak
        $uptime = $until - $started
        if (-not $StatsOnce) { Clear-Host }
        if ($ended) { $Host.UI.RawUI.WindowTitle = 'Lunos Toolbox | Session Summary' }
        $heading = if ($ended) { 'SESSION SUMMARY' } else { 'LIVE STATS DASHBOARD' }
        Write-Host "  LUNOS TOOLBOX  /  $heading" -ForegroundColor Green
        Write-Host '  ================================================' -ForegroundColor DarkGreen
        if ($ended) {
            Write-Host ('  Duration       {0:dd}d {0:hh}h {0:mm}m {0:ss}s' -f $uptime)
            Write-Host "  Started        $($started.ToString('MMM d, yyyy  h:mm:ss tt'))"
            Write-Host "  Stopped        $($until.ToString('MMM d, yyyy  h:mm:ss tt'))"
            Write-Host "  Peak online    $peak" -ForegroundColor Cyan
            Write-Host "  Unique players $($playtime.Count)" -ForegroundColor Cyan
        } else {
            Write-Host ('  Uptime      {0:dd}d {0:hh}h {0:mm}m {0:ss}s' -f $uptime)
            Write-Host "  Connected   $($players.Count)" -ForegroundColor Cyan
            foreach ($player in ($players.Keys | Sort-Object)) { Write-Host "              $player" }
        }
        Write-Host
        Show-PlaytimeLeaderboard 'Session playtime leaderboard' $playtime
        Write-Host
        if ($null -eq $previousPlaytime) {
            Write-Host '  Global playtime leaderboard' -ForegroundColor Cyan
            Write-Host "    Unavailable. $globalStatsError" -ForegroundColor Yellow
        } else {
            $globalPlaytime = $previousPlaytime.Clone()
            foreach ($player in $playtime.Keys) {
                if (!$globalPlaytime.ContainsKey($player)) { $globalPlaytime[$player] = [TimeSpan]::Zero }
                $globalPlaytime[$player] += $playtime[$player]
            }
            Show-PlaytimeLeaderboard 'Global playtime leaderboard (including this session)' $globalPlaytime
        }
        Write-Host
        Write-Host '  Latest backup' -ForegroundColor Cyan
        foreach ($label in $destinations.Keys) {
            $folder = $destinations[$label]
            $status = 'Folder unavailable'
            if (Test-Path -LiteralPath $folder -PathType Container) {
                $last = Get-ChildItem -LiteralPath $folder -File -Filter '*.zip' -ErrorAction SilentlyContinue |
                    Where-Object Name -match '^(myworld|lunosworld-backup|bedrock-server)-' |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                $status = if ($last) { $last.LastWriteTime.ToString('MMM d, yyyy  h:mm:ss tt') } else { 'No backups found' }
            }
            Write-Host ('  {0,-12}{1}' -f $label, $status)
        }
        if ($StatsOnce) { break }
        if ($ended) {
            Write-Host
            [void](Read-Host '  Press Enter to close the session summary')
            break
        }
        Write-Host
        Write-Host '  Refreshes every 5 seconds' -ForegroundColor DarkGray
        Start-Sleep -Seconds 5
    } while ($true)
    exit
}

if ($StartupLog) {
    $Host.UI.RawUI.WindowTitle = 'Lunos Toolbox | Bedrock Console'
    Set-ConsoleTile
    Set-Location -LiteralPath $serverRoot
    & $exe 2>&1 | Tee-Object -FilePath $StartupLog
    $serverExitCode = $LASTEXITCODE
    $stopped = Get-Date
    if (Test-Path -LiteralPath $StartupLog) {
        try {
            $session = Get-SessionPlaytime -LogPath $StartupLog -Until $stopped
            if ($session.Playtime.Count -gt 0) {
                $totalsFile = Join-Path $PSScriptRoot 'GlobalServerStats\Playtime.txt'
                Save-GlobalPlaytime -Path $totalsFile -Session $session
                Write-Host "  Global playtime saved to $totalsFile" -ForegroundColor Green
            }
        } catch {
            Write-Host "  Could not save global playtime. $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  Session log: $StartupLog" -ForegroundColor Gray
        }
    }
    exit $serverExitCode
}

$result = 1
try {
    $Host.UI.RawUI.WindowTitle = 'Lunos Toolbox | Start Server'
    Set-ConsoleTile -Right -Bottom
    Write-Host '  LUNOS TOOLBOX  /  START SERVER' -ForegroundColor Green
    Write-Host
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "Server executable not found at $exe"
    }
    if (Get-Process bedrock_server -ErrorAction SilentlyContinue | Where-Object { -not $_.Path -or $_.Path -eq $exe }) {
        throw 'The Bedrock server is already running.'
    }

    Write-Host '  Starting server...' -ForegroundColor Cyan
    $StartupLog = Join-Path $serverRoot ('startup-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
    $arguments = '-NoProfile -NoExit -ExecutionPolicy Bypass -File "{0}" -StartupLog "{1}"' -f $PSCommandPath, $StartupLog
    $console = Start-Process -FilePath conhost.exe -ArgumentList "powershell.exe $arguments" -WorkingDirectory $serverRoot -PassThru
    $deadline = (Get-Date).AddSeconds(60)

    do {
        if ((Test-Path -LiteralPath $StartupLog) -and
            (Select-String -LiteralPath $StartupLog -SimpleMatch 'Server started.' -Quiet)) {
            Write-Host '  Success. Bedrock reported that the server started.' -ForegroundColor Green
            $result = 0
            try {
                $server = Get-Process bedrock_server -ErrorAction SilentlyContinue |
                    Where-Object Path -eq $exe | Select-Object -First 1
                if ($server) {
                    $statsArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -StartupLog "{1}" -StatsProcessId {2}' -f $PSCommandPath, $StartupLog, $server.Id
                    Start-Process -FilePath conhost.exe -ArgumentList "powershell.exe $statsArgs" -WorkingDirectory $serverRoot
                }
            } catch {
                Write-Host "  Stats console unavailable. $($_.Exception.Message)" -ForegroundColor Yellow
            }
            break
        }
        if ($console.HasExited) { throw 'The server console exited during startup.' }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    if ($result -ne 0) { throw 'Bedrock did not report startup within 60 seconds. Check the server console.' }
} catch {
    Write-Host "  Startup failed. $($_.Exception.Message)" -ForegroundColor Red
    if ($StartupLog) { Write-Host "  Log  $StartupLog" -ForegroundColor Gray }
} finally {
    Write-Host '  This launcher closes in 5 seconds.' -ForegroundColor Gray
    Start-Sleep -Seconds 5
}
exit $result

