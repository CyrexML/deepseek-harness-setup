# Полное удаление стенда «Harness AI».
#
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1
#
# Ключи:
#   -KeepModel     оставить скачанные модели (13+ ГБ — качать заново долго)
#   -KeepData      оставить переписки, память агента и настройки (~/.dsh)
#   -KeepWsl       не удалять дистрибутив WSL целиком (по умолчанию он и не удаляется)
#   -RemoveWsl     удалить дистрибутив WSL ЦЕЛИКОМ — вместе со всем, что в нём есть
#   -Yes           не спрашивать подтверждения
#
# Что удаляется по умолчанию: ярлыки и задача планировщика, правило брандмауэра,
# движок llama.cpp, каталоги стенда внутри WSL (~/Harness_AI, ~/tools/deepseek-harness,
# ~/harness-stand) и данные DSH (~/.dsh). Модели — тоже, если не задан -KeepModel.
# Windows, WSL, драйверы и Node.js не трогаются: их ставили не мы одни.
[CmdletBinding()]
param(
  [switch]$KeepModel,
  [switch]$KeepData,
  [switch]$KeepWsl,
  [switch]$RemoveWsl,
  # Полное удаление «под ноль»: всё вышеперечисленное плюс дистрибутив WSL
  # целиком. Отдельный ключ, потому что в дистрибутиве могут быть чужие данные.
  [switch]$All,
  [switch]$Yes
)
if ($All) { $RemoveWsl = $true; $KeepModel = $false; $KeepData = $false }
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\windows\lib.ps1"

$cfg = Read-StandConfig
$root = $cfg.windowsRoot
$distro = $cfg.wslDistro

Write-Host ''
Write-Host '  Удаление стенда Harness AI' -ForegroundColor Yellow
Write-Host ''
Write-Host '  будет удалено:'
Write-Host "    - ярлыки, задача планировщика, правило брандмауэра (порт $($cfg.modelPort))"
Write-Host "    - движок и скрипты запуска: $root\llama.cpp, $root\run"
if (-not $KeepModel) { Write-Host "    - модели: $root\models" } else { Write-Host '    - модели: ОСТАЮТСЯ (-KeepModel)' }
if (-not $KeepData)  { Write-Host '    - данные DSH внутри WSL: ~/.dsh (переписки, память агента, настройки)' }
else { Write-Host '    - данные DSH: ОСТАЮТСЯ (-KeepData)' }
Write-Host '    - код стенда внутри WSL: ~/Harness_AI, ~/tools/deepseek-harness, ~/harness-stand'
if ($RemoveWsl) { Write-Host "    - ДИСТРИБУТИВ WSL «$distro» ЦЕЛИКОМ" -ForegroundColor Red }
Write-Host ''
Write-Host '  НЕ трогаем: саму Windows, WSL как компонент системы, драйвер видеокарты и ваши проекты вне стенда.'
Write-Host ''
Write-Host '  Режимы:' -ForegroundColor Cyan
Write-Host '    uninstall.cmd                 обычное удаление (спросит подтверждение)'
Write-Host '    uninstall.cmd -KeepModel      оставить скачанные модели (их долго качать заново)'
Write-Host '    uninstall.cmd -KeepData       оставить переписки, память агента и настройки'
Write-Host '    uninstall.cmd -All            ПОД НОЛЬ: всё выше + дистрибутив WSL целиком'
Write-Host ''

if (-not $Yes) {
  $answer = Read-Host '  Удалить? Напишите "удалить" для подтверждения'
  if ($answer -ne 'удалить') { Write-Host '  отменено'; return }
}

function Try-Do([string]$what, [scriptblock]$action) {
  Write-Step $what
  try { & $action; Write-Ok 'готово' } catch { Write-Warn "не удалось: $($_.Exception.Message)" }
}

Try-Do 'останавливаю стенд' {
  $stop = Join-Path $root 'run\harness-stop.ps1'
  if (Test-Path $stop) { & powershell -NoProfile -ExecutionPolicy Bypass -File $stop | Out-Null }
  $stopServer = Join-Path $root 'run\stop-server.ps1'
  if (Test-Path $stopServer) { & powershell -NoProfile -ExecutionPolicy Bypass -File $stopServer | Out-Null }
  Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  & wsl.exe -d $distro -- bash -lc 'pkill -f "bin.js web" 2>/dev/null; pkill -f cloudflared 2>/dev/null; true' 2>$null
}

Try-Do 'возвращаю таймауты сна' {
  $idle = Join-Path $root 'run\harness-idle-sleep.ps1'
  if (Test-Path $idle) { & powershell -NoProfile -ExecutionPolicy Bypass -File $idle -On | Out-Null }
  else { & powercfg.exe /change standby-timeout-ac 15 | Out-Null }
}

Try-Do 'удаляю задачу планировщика' {
  Get-ScheduledTask -TaskName 'Harness AI power restore' -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
}

Try-Do 'удаляю ярлыки' {
  foreach ($dir in @([Environment]::GetFolderPath('Desktop'),
                     (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))) {
    Get-ChildItem -Path $dir -Filter 'Harness AI*.lnk' -ErrorAction SilentlyContinue | Remove-Item -Force
  }
}

Try-Do 'удаляю правило брандмауэра' {
  Get-NetFirewallRule -DisplayName "Harness AI*" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

Try-Do 'удаляю содержимое стенда внутри WSL' {
  $keep = if ($KeepData) { 'true' } else { 'rm -rf "$HOME/.dsh"' }
  & wsl.exe -d $distro -- bash -lc "rm -rf `"`$HOME/Harness_AI`" `"`$HOME/tools/deepseek-harness`" `"`$HOME/harness-stand`"; $keep" 2>$null
}

Try-Do 'удаляю движок и скрипты запуска' {
  foreach ($sub in @('llama.cpp', 'run', 'exchange')) {
    $path = Join-Path $root $sub
    if (Test-Path $path) { Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue }
  }
}

if (-not $KeepModel) {
  Try-Do 'удаляю модели' {
    $models = Join-Path $root 'models'
    if (Test-Path $models) { Remove-Item -Recurse -Force $models -ErrorAction SilentlyContinue }
  }
}

Try-Do 'убираю пустой каталог стенда' {
  if ((Test-Path $root) -and -not (Get-ChildItem $root -Force -ErrorAction SilentlyContinue)) {
    Remove-Item -Force $root -ErrorAction SilentlyContinue
  }
}

if ($RemoveWsl -and -not $KeepWsl) {
  Write-Warn "удаляю дистрибутив WSL «$distro» целиком — это снесёт ВСЁ, что в нём было"
  if (-not $Yes) {
    $answer = Read-Host "  Точно удалить дистрибутив $distro? Напишите его имя"
    if ($answer -ne $distro) { Write-Host '  дистрибутив оставлен' }
    else { & wsl.exe --unregister $distro }
  } else { & wsl.exe --unregister $distro }
}

Write-Host ''
Write-Done 'стенд удалён'
Write-Host '  Остались нетронутыми: Windows, WSL, драйвер NVIDIA, Node.js внутри дистрибутива.'
if ($KeepModel) { Write-Host "  Модели остались в $root\models — при новой установке мастер их подхватит." }
if ($KeepData)  { Write-Host '  Данные DSH остались в ~/.dsh внутри WSL.' }
Write-Host ''
