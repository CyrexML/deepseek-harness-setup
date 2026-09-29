# Independent shutdown of the Harness AI stand.
#
# For the case where the launcher window was closed or the system was started by
# hand: the launcher stops everything itself, but a single path to shutdown is
# not something to rely on.
$ErrorActionPreference = 'Continue'
chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# These scripts are copied into <windowsRoot>\run, so the script's OWN folder is
# RunDir. The author's F: used to be baked in here and nothing substituted it at
# install time - so on any other drive the launcher looked for its files where
# they were not, and silently did nothing at all.
$RunDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# Written next to these scripts by 40-shortcuts.ps1, for the same reason.
$Distro = if (Test-Path "$RunDir\distro.txt") { (Get-Content -Raw "$RunDir\distro.txt").Trim() } else { 'Ubuntu' }

Write-Host '=== stopping Harness AI ===' -ForegroundColor Cyan

# Web interface. The `wsl.exe` holder may have survived the window closing.
& wsl.exe -d $Distro -- bash -lc '~/Harness_AI/scripts/stop-web.sh' 2>&1 | Out-Null
Get-CimInstance Win32_Process -Filter "Name = 'wsl.exe'" |
  Where-Object { $_.CommandLine -like '*harness-web-fg.sh*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Write-Host 'web interface stopped'

# Model.
& "$RunDir\stop-server.ps1"

Write-Host ''
Write-Host 'Stop WSL as well? This closes ALL Ubuntu processes - editors, Docker,' -ForegroundColor Yellow
Write-Host 'open terminals.' -ForegroundColor Yellow
$ans = Read-Host 'Stop WSL? [y/N]'
if ($ans -match '^(y|Y)') { & wsl.exe --shutdown; Write-Host 'WSL stopped' }
else { Write-Host 'WSL left running' }

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Start-Sleep -Seconds 2
