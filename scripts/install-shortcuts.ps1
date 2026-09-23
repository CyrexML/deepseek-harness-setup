# Installs the Harness AI shortcut into the Start menu.
# Run it after every launcher change: it also deploys the launcher.
#
# There is ONE shortcut and it works as a toggle; an older separate "stop"
# shortcut is removed if it is still around.
$ErrorActionPreference = 'Stop'
chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$RunDir = 'F:\Harness_AI\run'
$Folder = Join-Path ([Environment]::GetFolderPath('Programs')) 'Harness AI'
New-Item -ItemType Directory -Force -Path $Folder | Out-Null

# Deploy the launchers from the WSL repository - that is the source of truth.
& wsl.exe -d Ubuntu -- bash -lc `
  "cp ~/Harness_AI/scripts/harness-start.ps1 ~/Harness_AI/scripts/harness-stop.ps1 ~/Harness_AI/scripts/start-server.ps1 ~/Harness_AI/scripts/stop-server.ps1 ~/Harness_AI/scripts/harness-launch.vbs ~/Harness_AI/scripts/harness-splash.ps1 ~/Harness_AI/scripts/splash-whale.png ~/Harness_AI/scripts/harness.ico /mnt/f/Harness_AI/run/"

$shell = New-Object -ComObject WScript.Shell
$path  = Join-Path $Folder 'Harness AI.lnk'
$lnk = $shell.CreateShortcut($path)
# No console: wscript //B -> harness-launch.vbs -> powershell -Hidden. Shutdown is
# the Power button in the web UI (Settings -> Remote access) or a second click.
$lnk.TargetPath = "$env:SystemRoot\System32\wscript.exe"
$lnk.Arguments  = "//B `"$RunDir\harness-launch.vbs`""
$lnk.WorkingDirectory = $RunDir
$lnk.Description = 'Start and stop the local agent: model plus the dsh web interface'
# The icon is rebuilt from the dsh build's favicon by scripts/make-icon.sh. The
# path must be a Windows one: the shortcut reads it itself, before any WSL.
$lnk.IconLocation = "$RunDir\harness.ico,0"
$lnk.Save()
Write-Host "installed: $path"

$old = Join-Path $Folder 'Harness AI - stop.lnk'
if (Test-Path $old) { Remove-Item -Force $old; Write-Host "removed the old stop shortcut: $old" }

Write-Host ''
Write-Host 'Done. The shortcut is in the Start menu, folder "Harness AI".' -ForegroundColor Green
Write-Host 'The first click starts the system (windowless), the second stops it; stopping with WSL is in the web UI: Settings -> Remote access -> Power.'
