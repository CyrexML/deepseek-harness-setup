# Independent shutdown of the Harness AI stand.
#
# For the case where the launcher window was closed or the system was started by
# hand: the launcher stops everything itself, but a single path to shutdown is
# not something to rely on.
$ErrorActionPreference = 'Continue'
chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$Distro = 'Ubuntu'
$RunDir = 'F:\Harness_AI\run'

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
