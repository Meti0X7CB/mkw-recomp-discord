<#
  Sets up mkw-recomp-discord: checks PowerShell 7 and Discord, finds the game, and makes a
  "Mario Kart World (Discord)" shortcut that starts the game with Discord status and no
  console window. Also prints the settings for a Steam (non-Steam game) entry.

  -Desktop    also put the shortcut on the desktop
  -StartMenu  also put the shortcut in the Start menu
  -NoPause    don't wait for Enter at the end
#>
param([switch]$Desktop, [switch]$StartMenu, [switch]$NoPause)

# "Run with PowerShell" closes the window when the script ends; keep messages readable.
trap { Write-Host $_ -ForegroundColor Red; if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }; exit 1 }
function Stop-Install([int]$code) { if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }; exit $code }

$ErrorActionPreference = 'Stop'
$here   = $PSScriptRoot
$script = Join-Path $here 'mkw-discord.ps1'

Get-ChildItem $here -File | Unblock-File -ErrorAction SilentlyContinue

$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwsh) {
    Write-Host "PowerShell 7 is required. Install it with:" -ForegroundColor Yellow
    Write-Host "  winget install Microsoft.PowerShell"
    Write-Host "then run this installer again."
    Stop-Install 1
}
$pwsh = $pwsh.Source

Write-Host "Checking the game and Discord..."
& $pwsh -NoProfile -ExecutionPolicy Bypass -File $script -Test
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Fix the problem above (start Discord, or set game_exe in config.ini) and run this again." -ForegroundColor Yellow
    Stop-Install 1
}

$conhost = Join-Path $env:WINDIR 'System32\conhost.exe'
$lnkArgs ="--headless `"$pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$script`""
$cfgText = Get-Content (Join-Path $here 'config.ini') -Raw
$icon    = $null
$exeLine = [regex]::Match($cfgText, '(?m)^\s*game_exe\s*=\s*"?(.+?)"?\s*$')
foreach ($c in @($(if ($exeLine.Success) { $exeLine.Groups[1].Value }), (Join-Path $here 'mkw.exe'), (Join-Path $here '..\mkw.exe'))) {
    if ($c -and (Test-Path -LiteralPath $c)) { $icon = "$([IO.Path]::GetFullPath($c)),0"; break }
}

$shell   = New-Object -ComObject WScript.Shell
$targets = @(Join-Path $here 'Mario Kart World (Discord).lnk')
if ($Desktop)   { $targets += Join-Path ([Environment]::GetFolderPath('Desktop')) 'Mario Kart World (Discord).lnk' }
if ($StartMenu) { $targets += Join-Path ([Environment]::GetFolderPath('Programs')) 'Mario Kart World (Discord).lnk' }
foreach ($t in $targets) {
    $lnk = $shell.CreateShortcut($t)
    $lnk.TargetPath       = $conhost
    $lnk.Arguments        = $lnkArgs
    $lnk.WorkingDirectory = $here
    $lnk.Description      = 'Mario Kart World with Discord Rich Presence'
    if ($icon) { $lnk.IconLocation = $icon }
    $lnk.Save()
    Write-Host "Shortcut: $t" -ForegroundColor Green
}

Write-Host ""
Write-Host "To launch from Steam, open the game's Properties and set:" -ForegroundColor Cyan
Write-Host "  Target:         `"$conhost`""
Write-Host "  Start In:       `"$here`""
Write-Host "  Launch Options: $lnkArgs"
Stop-Install 0
