# Глушитель сна по простою для стенда, запущенного НЕ через лончер.
#
# Зачем. harness-start.ps1 на время работы ставит standby/hibernate-timeout-ac
# в 0 и возвращает прежние значения при остановке. Но стенд можно поднять и
# напрямую из WSL (scripts/start-web.sh) — тогда таймауты остаются штатными
# (на этом ПК 15 минут от сети), и Windows усыпляет машину прямо посреди
# работы агента: нагрузка на CPU/GPU простоем НЕ считается, нужен ввод с
# клавиатуры или мыши. 2026-09-23: семь засыпаний за два часа (журнал System,
# Kernel-Power 42), из-за чего работа рвалась и выглядела как выключение ПК.
#
# Протокол тот же, что у лончера: прежние значения лежат в power-timeouts.json,
# и если процесс умрёт, их вернёт задача планировщика «Harness AI power restore».
#
#   harness-idle-sleep.ps1 -Off   выключить сон по простою (сохранив прежнее)
#   harness-idle-sleep.ps1 -On    вернуть прежние значения
#   harness-idle-sleep.ps1        показать текущее состояние
#
# Прав администратора не требует. Гашение экрана (VIDEOIDLE) НЕ трогается:
# погасший монитор работе не мешает.
param(
  [switch]$Off,
  [switch]$On,
  # На сколько гасить экран, если у пользователя стоит «никогда». Сам стенд от
  # погасшего монитора не страдает.
  [int]$MonitorMinutes = 10,
  [string]$Saved = 'F:\Harness_AI\run\power-timeouts.json'
)

$RunDir = Split-Path -Parent $Saved
$LauncherLog = Join-Path $RunDir 'launcher.log'
function Log([string]$m) {
  try { Add-Content -Path $LauncherLog -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " [idle-sleep] " + $m) } catch { }
}

# 4-е hex-число в выводе powercfg /q — индекс «от сети» (мин, макс, шаг, AC, DC).
# Порядок не зависит от языка системы, поэтому парсим позиционно, а не по словам.
function Get-AcTimeoutMinutes([string]$setting, [string]$subgroup = 'SUB_SLEEP') {
  $out = & powercfg.exe /q SCHEME_CURRENT $subgroup $setting 2>$null | Out-String
  $m = [regex]::Matches($out, '0x[0-9a-fA-F]{8}')
  if ($m.Count -lt 5) { return $null }
  return [int]([Convert]::ToInt32($m[3].Value, 16) / 60)
}

function Show-State {
  $standby = Get-AcTimeoutMinutes 'STANDBYIDLE'
  $hib = Get-AcTimeoutMinutes 'HIBERNATEIDLE'
  $video = Get-AcTimeoutMinutes 'VIDEOIDLE' 'SUB_VIDEO'
  $state = if ($standby -eq 0) { 'sleep disabled' } else { "sleep after $standby min" }
  $screen = if ($video -eq 0) { 'screen stays on' } else { "screen off after $video min" }
  Write-Host ("standby-timeout-ac = {0} min, hibernate-timeout-ac = {1} min, monitor-timeout-ac = {2} min -> {3}, {4}" -f $standby, $hib, $video, $state, $screen)
  if (Test-Path $Saved) { Write-Host ("saved values: " + (Get-Content -Raw $Saved)) }
}

if ($Off) {
  if (-not (Test-Path $Saved)) {
    $values = @{}
    foreach ($pair in @(@('STANDBYIDLE', 'standby-timeout-ac'), @('HIBERNATEIDLE', 'hibernate-timeout-ac'))) {
      $min = Get-AcTimeoutMinutes $pair[0]
      if ($null -ne $min) { $values[$pair[1]] = $min }
    }
    $video = Get-AcTimeoutMinutes 'VIDEOIDLE' 'SUB_VIDEO'
    if ($null -ne $video) { $values['monitor-timeout-ac'] = $video }
    if ($values.Count -gt 0) { $values | ConvertTo-Json | Set-Content -Encoding UTF8 $Saved }
  }
  foreach ($name in @('standby-timeout-ac', 'hibernate-timeout-ac')) { & powercfg.exe /change $name 0 | Out-Null }

  # Экран гасить НУЖНО: он не мешает работе (ни локальной, ни с телефона — стенд
  # живёт в фоне), а вот гореть всю ночь ему незачем. Трогаем только случай
  # «никогда»: осмысленную настройку пользователя не переписываем.
  $video = Get-AcTimeoutMinutes 'VIDEOIDLE' 'SUB_VIDEO'
  if ($video -eq 0) {
    & powercfg.exe /change monitor-timeout-ac $MonitorMinutes | Out-Null
    Log ("monitor timeout was 'never' -> set to $MonitorMinutes min for the session")
  }

  Log 'idle sleep disabled (stand started outside the launcher)'
  Show-State
  exit 0
}

if ($On) {
  # Лончер жив — состояние принадлежит ему, не вмешиваемся.
  $launcher = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*harness-start.ps1*' }
  if ($launcher) { Log 'restore skipped: launcher is running and owns the timeouts'; Show-State; exit 0 }
  if (-not (Test-Path $Saved)) { Show-State; exit 0 }
  try {
    $values = Get-Content -Raw $Saved | ConvertFrom-Json
    foreach ($p in $values.PSObject.Properties) { & powercfg.exe /change $p.Name ([int]$p.Value) | Out-Null }
    Remove-Item -Force $Saved -ErrorAction SilentlyContinue
    Log ('idle sleep restored: ' + (($values.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '))
  } catch { Log "restore failed: $_" }
  Show-State
  exit 0
}

Show-State
