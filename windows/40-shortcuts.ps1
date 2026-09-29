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

# Registering the scheduled task needs elevation, and run as an ordinary user
# this step died on a raw CIM "access denied" in the system language. Said here,
# before anything is written, it costs one line instead of a puzzle.
if (-not (Test-Admin)) {
  Write-Warn 'this step needs administrator rights (it registers a scheduled task)'
  Write-Info 'right-click install.cmd -> Run as administrator, or open PowerShell as administrator first'
  exit 2
}

$cfg = Read-StandConfig
$root = $cfg.windowsRoot
$runDir = Join-Path $root 'run'
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

Write-Step 'launch scripts into run\'
# The scripts live inside WSL; the Windows side needs copies next to the model.
$wslHome = (& wsl.exe -d $cfg.wslDistro -- bash -lc 'echo $HOME').Trim()
$wslRunSource = "/mnt/$($root.Substring(0,1).ToLower())$($root.Substring(2) -replace '\\','/')/run"
& wsl.exe -d $cfg.wslDistro -- bash -lc "cp `$HOME/Harness_AI/scripts/harness-start.ps1 `$HOME/Harness_AI/scripts/harness-stop.ps1 `$HOME/Harness_AI/scripts/harness-launch.vbs `$HOME/Harness_AI/scripts/harness-splash.ps1 `$HOME/Harness_AI/scripts/harness-idle-sleep.ps1 `$HOME/Harness_AI/scripts/harness-restore-power.ps1 `$HOME/Harness_AI/scripts/harness-hidden.vbs `$HOME/Harness_AI/scripts/harness.ico `$HOME/Harness_AI/scripts/splash-whale.png '$wslRunSource/' 2>/dev/null; true"
# The copied scripts find their own folder, but not the distribution name. It
# goes next to them, the same way the message language does.
Set-Content -Path (Join-Path $runDir 'distro.txt') -Value $cfg.wslDistro -Encoding ascii -NoNewline
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
$icon = Join-Path $runDir 'harness.ico'

if (Test-Path $launch) {
  # One shortcut, in the Start menu. It is a toggle - a second click stops the
  # stand - and the Power button in the web interface does the same job from the
  # phone, so a separate "stop" shortcut earned nothing but desktop clutter.
  New-Shortcut -Path (Join-Path $startMenu 'Harness AI.lnk') -Target "$env:WINDIR\System32\wscript.exe" `
    -Arguments "`"$launch`"" -Icon $icon -Description 'Start the Harness AI stand'
  # Anything this installer put on the desktop before is taken back off.
  foreach ($old in @('Harness AI.lnk', 'Harness AI - stop.lnk')) {
    Remove-Item (Join-Path $desktop $old) -Force -ErrorAction SilentlyContinue
  }
  Remove-Item (Join-Path $startMenu 'Harness AI - stop.lnk') -Force -ErrorAction SilentlyContinue
  Write-Ok 'created in the Start menu (search for "Harness")'
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
  try {
    Register-ScheduledTask -TaskName 'Harness AI power restore' -Action $action `
      -Trigger @($logon, $repeat) -Settings $settings -Force | Out-Null
    Write-Ok 'registered (at logon and every 15 minutes)'
  } catch {
    # Everything above is already in place; the stand runs without this task,
    # it only puts the sleep timeouts back if the stand was killed rather than
    # stopped. Not worth failing a finished install over.
    Write-Warn 'could not register the task: {0}' $_.Exception.Message
    Write-Info 'the stand works without it; it only restores the sleep timeouts after a hard stop.'
    Write-Info 'to try again:  install.cmd -Step shortcuts   (as administrator)'
  }
} else {
  Write-Warn 'no {0} - task skipped' $restore
}

Write-Done 'shortcuts and maintenance are set up'
