# Ярлыки, автозапуск и задача восстановления питания.
#
#   powershell -ExecutionPolicy Bypass -File windows\40-shortcuts.ps1
#
# Создаёт: ярлык «Harness AI» на рабочем столе и в меню «Пуск» (запускает стенд
# скрытым окном через harness-launch.vbs), ярлык «Harness AI — стоп», задачу
# планировщика, которая возвращает таймауты сна, если стенд упал вместе с
# системой, и копирует скрипты запуска в <windowsRoot>\run.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\lib.ps1"

$cfg = Read-StandConfig
$root = $cfg.windowsRoot
$runDir = Join-Path $root 'run'
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

Write-Step 'скрипты запуска в run\'
# Скрипты живут внутри WSL (их ставит wsl/30-patches.sh вместе с остальным
# деревом стенда); Windows-части нужны их копии рядом с моделью.
$wslHome = (& wsl.exe -d $cfg.wslDistro -- bash -lc 'echo $HOME').Trim()
$wslRunSource = "/mnt/$($root.Substring(0,1).ToLower())$($root.Substring(2) -replace '\\','/')/run"
& wsl.exe -d $cfg.wslDistro -- bash -lc "cp `$HOME/Harness_AI/scripts/harness-start.ps1 `$HOME/Harness_AI/scripts/harness-stop.ps1 `$HOME/Harness_AI/scripts/harness-launch.vbs `$HOME/Harness_AI/scripts/harness-splash.ps1 `$HOME/Harness_AI/scripts/harness-idle-sleep.ps1 `$HOME/Harness_AI/scripts/harness-restore-power.ps1 `$HOME/Harness_AI/scripts/harness-hidden.vbs `$HOME/Harness_AI/scripts/harness.ico `$HOME/Harness_AI/scripts/splash-whale.png '$wslRunSource/' 2>/dev/null; true"
Write-Ok 'скопированы'

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

Write-Step 'ярлыки'
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
  Write-Ok 'созданы на рабочем столе и в меню «Пуск»'
} else {
  Write-Warn "нет $launch — ярлыки пропущены (WSL-часть ещё не установлена?)"
}

Write-Step 'задача восстановления питания'
# Лончер на время работы ставит таймауты сна в 0. Если Windows перезагрузится
# сама (обновление), они остались бы нулевыми навсегда — задача возвращает их,
# когда ни лончер, ни интерфейс больше не работают.
$restore = Join-Path $runDir 'harness-restore-power.ps1'
if (Test-Path $restore) {
  # Через wscript: действие powershell.exe мигает окном консоли раз в 15 минут —
  # conhost создаёт окно раньше, чем PowerShell применяет -WindowStyle Hidden.
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
  Write-Ok 'зарегистрирована (вход в систему + каждые 15 минут)'
} else {
  Write-Warn "нет $restore — задача пропущена"
}

Write-Done 'ярлыки и обслуживание настроены'
