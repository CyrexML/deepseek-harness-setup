# Shortcuts, autostart and the power-restore task.
#
#   powershell -ExecutionPolicy Bypass -File windows\40-shortcuts.ps1
#
# Creates the Harness AI desktop and Start-menu shortcuts (launched windowless
# through harness-launch.vbs), a stop shortcut, a scheduled task that restores
# the sleep timeouts if the stand went down with the system, and copies the
# launch scripts into <windowsRoot>\run.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\lib.ps1"

$cfg = Read-StandConfig
$root = $cfg.windowsRoot
$runDir = Join-Path $root 'run'
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

Write-Step 'launch scripts into run\'
# The scripts live inside WSL; the Windows side needs copies next to the model.
$wslHome = (& wsl.exe -d $cfg.wslDistro -- bash -lc 'echo $HOME').Trim()
$wslRunSource = "/mnt/$($root.Substring(0,1).ToLower())$($root.Substring(2) -replace '\\','/')/run"
& wsl.exe -d $cfg.wslDistro -- bash -lc "cp `$HOME/Harness_AI/scripts/harness-start.ps1 `$HOME/Harness_AI/scripts/harness-stop.ps1 `$HOME/Harness_AI/scripts/harness-launch.vbs `$HOME/Harness_AI/scripts/harness-splash.ps1 `$HOME/Harness_AI/scripts/harness-idle-sleep.ps1 `$HOME/Harness_AI/scripts/harness-restore-power.ps1 `$HOME/Harness_AI/scripts/harness-hidden.vbs `$HOME/Harness_AI/scripts/harness.ico `$HOME/Harness_AI/scripts/splash-whale.png '$wslRunSource/' 2>/dev/null; true"
Write-Ok 'copied'

function New-Shortcut {
  param([string]$Path, [string]$Target, [string]$Arguments, [string]$Icon, [string]$Description)
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($Path)
  $link.TargetPath = $Target
  if ($Arguments) { $link.Arguments = $Arguments }
  if ($Icon -and (Test-Path $Icon)) { $link.IconLocation = $Icon }
  $link.Description = $Description
  $link.WorkingDirectory = Split-Path -Parent $Target
  $link.Save()
}

# Message language and catalogs for the launcher and the splash: they run from
# run\ and never see config.json, so the choice is written next to them.
$lang = if ($cfg.PSObject.Properties['lang'] -and $cfg.lang) { $cfg.lang } else { 'en' }
Set-Content -Path (Join-Path $runDir 'lang.txt') -Value $lang -Encoding UTF8 -NoNewline
$i18nSrc = Join-Path $script:StandRoot 'i18n'
if (Test-Path $i18nSrc) {
  $i18nDst = Join-Path $runDir 'i18n'
  New-Item -ItemType Directory -Force -Path $i18nDst | Out-Null
  Copy-Item "$i18nSrc\*.json" $i18nDst -Force
}
Write-Ok 'message language: {0}' $lang

Write-Step 'shortcuts'
$desktop = [Environment]::GetFolderPath('Desktop')
$startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$launch = Join-Path $runDir 'harness-launch.vbs'
$stop = Join-Path $runDir 'harness-stop.ps1'
$icon = Join-Path $runDir 'harness.ico'

if (Test-Path $launch) {
  foreach ($dir in @($desktop, $startMenu)) {
    New-Shortcut -Path (Join-Path $dir 'Harness AI.lnk') -Target "$env:WINDIR\System32\wscript.exe" `
      -Arguments "`"$launch`"" -Icon $icon -Description 'Запуск стенда Harness AI'
  }
  New-Shortcut -Path (Join-Path $desktop 'Harness AI — стоп.lnk') -Target "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -Arguments "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$stop`"" -Icon $icon -Description 'Остановка стенда Harness AI'
  Write-Ok 'created on the desktop and in the Start menu'
} else {
  Write-Warn 'no {0} - shortcuts skipped (WSL side not installed yet?)' $launch
}

Write-Step 'power-restore task'
# The launcher sets the sleep timeouts to 0 while it runs. If Windows reboots on
# its own they would stay at 0 forever, so this task restores them once neither
# the launcher nor the interface is alive.
$restore = Join-Path $runDir 'harness-restore-power.ps1'
if (Test-Path $restore) {
  # Run through wscript: a powershell.exe action flashes a console window every
  # 15 minutes, because conhost creates it before -WindowStyle Hidden applies.
  $hidden = Join-Path $runDir 'harness-hidden.vbs'
  $action = if (Test-Path $hidden) {
    New-ScheduledTaskAction -Execute "$env:WINDIR\System32\wscript.exe" -Argument "`"$hidden`" `"$restore`""
  } else {
    New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$restore`""
  }
  $logon = New-ScheduledTaskTrigger -AtLogOn
  $logon.Delay = 'PT30S'
  $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650)
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  Register-ScheduledTask -TaskName 'Harness AI power restore' -Action $action `
    -Trigger @($logon, $repeat) -Settings $settings -Force | Out-Null
  Write-Ok 'registered (at logon and every 15 minutes)'
} else {
  Write-Warn 'no {0} - task skipped' $restore
}

Write-Done 'shortcuts and maintenance are set up'
