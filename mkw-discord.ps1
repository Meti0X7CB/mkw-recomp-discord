#Requires -Version 7
<#
  Discord Rich Presence for MKW Recomp (https://github.com/adriadam10/mkw-recomp).

  Launches mkw.exe (or attaches if it is already running), reads the port's log to tell
  whether you're starting up, in the menus or in a race, and shows that on your Discord
  profile through Discord's local IPC pipe. The status clears when the game closes.

  -NoLaunch  only attach to a running game; don't start one
  -Test      check the Discord connection and client_id, then exit
#>
param([switch]$NoLaunch, [switch]$Test)

$ErrorActionPreference = 'Stop'
$here    = $PSScriptRoot
$logPath = Join-Path $here 'mkw-discord.log'
Set-Content $logPath "" -ErrorAction SilentlyContinue
function Write-Log([string]$m) {
    $line = "$(Get-Date -Format 'HH:mm:ss') $m"
    Add-Content $logPath $line -ErrorAction SilentlyContinue
    if ($Test) { Write-Host $line }
}

# ---------- config ----------
$cfg = @{}
foreach ($line in Get-Content (Join-Path $here 'config.ini')) {
    if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$') { $cfg[$Matches[1]] = $Matches[2].Trim('"') }
}
function Resolve-ConfigPath([string]$p) {
    if (-not $p) { return $null }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $here $p }
    return [IO.Path]::GetFullPath($p)
}

# game_exe: set in config.ini, or found next to / one folder above this script.
$gameExe = Resolve-ConfigPath $cfg.game_exe
if (-not $gameExe) {
    $gameExe = @('mkw.exe', '..\mkw.exe') |
        ForEach-Object { [IO.Path]::GetFullPath((Join-Path $here $_)) } |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $gameExe -or -not (Test-Path -LiteralPath $gameExe)) {
    Write-Log "can't find mkw.exe: put this folder inside your MKW Recomp folder, or set game_exe in config.ini"
    if ($Test) { Write-Host "FAILED: mkw.exe not found" }
    exit 2
}

# game_log: set in config.ini, or <game data folder>\logs\mkw.log. The launcher's mkw.ini
# names the game data folder ([launcher] game_dir); without it, it's mkw.exe's own folder.
$gameLog = Resolve-ConfigPath $cfg.game_log
if (-not $gameLog) {
    $gameDir = Split-Path $gameExe
    $launcherIni = Join-Path $gameDir 'mkw.ini'
    if (Test-Path -LiteralPath $launcherIni) {
        $m = Select-String -LiteralPath $launcherIni -Pattern '^\s*game_dir\s*=\s*"?(.*?)"?\s*$' | Select-Object -First 1
        if ($m) { $gameDir = $m.Matches[0].Groups[1].Value }
    }
    $gameLog = Join-Path $gameDir 'logs\mkw.log'
}

function Start-Game {
    if (-not $NoLaunch -and -not (Get-GameProcess)) {
        Write-Log "starting $gameExe"
        Start-Process -FilePath $gameExe -WorkingDirectory (Split-Path $gameExe) | Out-Null
    }
}
function Get-GameProcess {
    $name = [IO.Path]::GetFileNameWithoutExtension($gameExe)
    Get-Process -Name $name -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1
}

if ($cfg.client_id -notmatch '^\d{15,22}$') {
    Write-Log "client_id is missing in config.ini; launching the game without Discord status"
    if (-not $Test) { Start-Game }
    exit 1
}

# Only one presence client at a time; a second launch just starts the game.
$mutex = [Threading.Mutex]::new($false, 'Local\mkw-discord-presence')
if (-not $mutex.WaitOne(0)) {
    if (-not $Test) { Start-Game }
    exit 0
}

# ---------- Discord IPC ----------
$script:pipe = $null

function Send-Frame([int]$op, $payload) {
    $json  = [Text.Encoding]::UTF8.GetBytes(($payload | ConvertTo-Json -Depth 10 -Compress))
    $frame = [byte[]]::new(8 + $json.Length)
    [BitConverter]::GetBytes($op).CopyTo($frame, 0)
    [BitConverter]::GetBytes($json.Length).CopyTo($frame, 4)
    $json.CopyTo($frame, 8)
    $script:pipe.Write($frame, 0, $frame.Length)
    $script:pipe.Flush()
}

function Read-Frame {
    $head = [byte[]]::new(8)
    $script:pipe.ReadExactly($head, 0, 8)
    $op   = [BitConverter]::ToInt32($head, 0)
    $body = [byte[]]::new([BitConverter]::ToInt32($head, 4))
    $script:pipe.ReadExactly($body, 0, $body.Length)
    [pscustomobject]@{ Op = $op; Data = [Text.Encoding]::UTF8.GetString($body) | ConvertFrom-Json }
}

# Reads until the reply to our command, answering pings; op 2 means Discord closed us.
function Read-Reply([string]$nonce) {
    while ($true) {
        $f = Read-Frame
        switch ($f.Op) {
            2 { throw "Discord closed the connection: $($f.Data.message) ($($f.Data.code))" }
            3 { Send-Frame 4 $f.Data }
            1 { if (-not $nonce -or $f.Data.nonce -eq $nonce) { return $f.Data } }
        }
    }
}

function Close-Discord {
    if ($script:pipe) { try { $script:pipe.Dispose() } catch {} }
    $script:pipe = $null
}

function Connect-Discord {
    for ($i = 0; $i -lt 10; $i++) {
        $p = [IO.Pipes.NamedPipeClientStream]::new('.', "discord-ipc-$i", [IO.Pipes.PipeDirection]::InOut)
        try { $p.Connect(250) } catch { $p.Dispose(); continue }
        $script:pipe = $p
        try {
            Send-Frame 0 @{ v = 1; client_id = $cfg.client_id }
            $ready = Read-Reply $null
            if ($ready.evt -ne 'READY') { throw "unexpected handshake reply: $($ready | ConvertTo-Json -Compress)" }
            Write-Log "connected to Discord (discord-ipc-$i) as $($ready.data.user.username)"
            return $true
        } catch {
            Write-Log "handshake on discord-ipc-${i} failed: $($_.Exception.Message)"
            Close-Discord
        }
    }
    return $false
}

function Set-Activity($activity) {
    $nonce = [guid]::NewGuid().ToString()
    Send-Frame 1 @{ cmd = 'SET_ACTIVITY'; args = @{ pid = $PID; activity = $activity }; nonce = $nonce }
    $reply = Read-Reply $nonce
    if ($reply.evt -eq 'ERROR') { throw "SET_ACTIVITY failed: $($reply.data.message)" }
}

if ($Test) {
    Write-Host "game: $gameExe"
    Write-Host "log:  $gameLog"
    if (Connect-Discord) { Close-Discord; Write-Host "OK: Discord accepted client_id $($cfg.client_id)"; exit 0 }
    Write-Host "FAILED: see messages above (is Discord running, and is client_id right?)"; exit 1
}

# ---------- game state from the port's log ----------
$script:logStamp = $null
$script:lastState = 'Starting up'
$script:portVersion = $null

function Get-GameState($proc) {
    if (-not (Test-Path -LiteralPath $gameLog)) { return 'Starting up' }
    $fi = Get-Item -LiteralPath $gameLog
    # The port rotates mkw.log at startup; a log older than the process is from the last run.
    if ($fi.LastWriteTime -lt $proc.StartTime.AddSeconds(-2)) { return 'Starting up' }
    $stamp = "$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
    if ($stamp -eq $script:logStamp) { return $script:lastState }
    $script:logStamp = $stamp

    $fs = [IO.FileStream]::new($gameLog, 'Open', 'Read', [IO.FileShare]'ReadWrite, Delete')
    try { $text = [IO.StreamReader]::new($fs).ReadToEnd() } finally { $fs.Dispose() }

    $v = [regex]::Match($text, '\(MKW Recomp ([^)\s]+)\)')
    if ($v.Success) { $script:portVersion = $v.Groups[1].Value }

    $state = if ($text.IndexOf('[host] boot: guest starts') -lt 0) { 'Starting up' }
             elseif ($text.LastIndexOf('[host] race: in a race') -gt $text.LastIndexOf('[host] race: out of the race')) { 'Racing' }
             else { 'In the menus' }
    $script:lastState = $state
    return $state
}

function New-Activity([string]$state, [long]$startUnix) {
    $a = @{ details = $state; timestamps = @{ start = $startUnix } }
    $credit = 'Mario Kart World'
    if ($cfg.project_name) {
        $credit = (@($cfg.project_name, $script:portVersion) | Where-Object { $_ }) -join ' '
        $a.state = $credit
    }
    if ($cfg.project_url) {
        $a.state_url = $cfg.project_url
        $label = if ($cfg.button_label) { $cfg.button_label } else { 'Project page' }
        $a.buttons = @(@{ label = $label.Substring(0, [Math]::Min(32, $label.Length)); url = $cfg.project_url })
    }
    if ($cfg.large_image) {
        $a.assets = @{ large_image = $cfg.large_image; large_text = "Mario Kart World on PC via $credit" }
        if ($cfg.project_url) { $a.assets.large_url = $cfg.project_url }
    }
    return $a
}

# ---------- main loop ----------
Start-Game
$sent       = $null       # state currently shown on Discord
$nextTry    = [datetime]::MinValue
$goneSince  = $null
$startUnix  = 0

try {
    while ($true) {
        $proc = Get-GameProcess
        if (-not $proc) {
            # Give a launcher/updater a moment to hand off before calling it closed.
            if (-not $goneSince) { $goneSince = Get-Date }
            elseif (((Get-Date) - $goneSince).TotalSeconds -gt 20) { Write-Log "game closed"; break }
            Start-Sleep -Seconds 2
            continue
        }
        $goneSince = $null
        $startUnix = [DateTimeOffset]::new($proc.StartTime).ToUnixTimeSeconds()

        $state = Get-GameState $proc
        $key   = "$state|$startUnix"

        if (-not $script:pipe -and (Get-Date) -ge $nextTry) {
            if (-not (Connect-Discord)) { $nextTry = (Get-Date).AddSeconds(15) }
            $sent = $null
        }
        if ($script:pipe -and $key -ne $sent) {
            try {
                Set-Activity (New-Activity $state $startUnix)
                Write-Log "status: $state"
                $sent = $key
            } catch {
                Write-Log "lost Discord: $($_.Exception.Message)"
                Close-Discord
                $nextTry = (Get-Date).AddSeconds(15)
            }
        }
        Start-Sleep -Seconds 3
    }
} finally {
    if ($script:pipe) { try { Set-Activity $null } catch {} }
    Close-Discord
    $mutex.ReleaseMutex()
}
