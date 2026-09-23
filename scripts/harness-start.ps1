# Единая точка входа в систему Harness_AI: модель + веб-интерфейс dsh.
# Ярлык в меню Пуск один, и он же ПЕРЕКЛЮЧАТЕЛЬ: система погашена — клик
# поднимает её, система работает — клик гасит.
#
# Ставится через install-shortcuts.ps1.
#
# Порядок запуска не произволен. llama-server поднимается ПЕРВЫМ, потому что
# start-web.sh отказывается стартовать, если модель не отвечает.
#
# llama-server намеренно запускается ПРИВЯЗАННЫМ к этому окну: тогда закрытие
# окна крестиком гасит модель, даже если очистка не успела отработать.
# -Hidden: режим ярлыка через harness-launch.vbs — консоли нет, вместо Enter
# скрипт ждёт файл-сигнал power.request (кнопки Power в вебе) или второй клик.
param([switch]$NoBrowser, [switch]$Hidden)

$ErrorActionPreference = 'Stop'
chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$Distro = 'Ubuntu'
$RunDir = 'F:\Harness_AI\run'
# Порог предупреждения о видеопамяти после старта (МиБ). Норма стенда на 64k —
# ~250 свободных; при нехватке драйвер молча вытесняет веса в ОЗУ (−10×,
# known-limitations §13). Потребители помимо llama-server — DWM, ProtonVPN,
# браузеры; их список пишется в launcher.log при каждом старте.
$VramWarnMiB = 100
$Repo   = '~/Harness_AI'
$WebLog = "$Repo/run/web.log"
$Holder = $null
# Файл-сигнал от bridge (Settings → Remote access → Power): {"mode":"dsh"|"wsl"}.
# Путь совпадает с DSH_POWER_REQUEST_FILE в start-web.sh (/mnt/f/…).
$PowerRequest = "$RunDir\power.request"
# Сохранённые таймауты сна на время работы (см. Disable-IdleSleep).
$PowerSaved = "$RunDir\power-timeouts.json"
# Стадии запуска для экрана загрузки (harness-splash.ps1) в скрытом режиме.
$LaunchStatus = "$RunDir\launch.status"
# Журнал лончера: в скрытом режиме это единственный след того, что он делал.
$LauncherLog = "$RunDir\launcher.log"
# Ротация: свыше 1 МБ — в launcher.log.1 (история инцидентов не должна теряться,
# но и расти бесконечно тоже).
function Log([string]$m) {
  try {
    if ((Test-Path $LauncherLog) -and (Get-Item $LauncherLog).Length -gt 1MB) { Move-Item -Force $LauncherLog "$LauncherLog.1" }
    Add-Content -Path $LauncherLog -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " [$PID] " + $m)
  } catch { }
}

function Wsl([string]$cmd) { & wsl.exe -d $Distro -- bash -lc $cmd }

# Держателем считается `wsl.exe`, запустивший harness-web-fg.sh: именно под ним
# первым планом работает node, и по нему систему видно из любого окна.
function Get-WebHolders {
  Get-CimInstance Win32_Process -Filter "Name = 'wsl.exe'" |
    Where-Object { $_.CommandLine -like '*harness-web-fg.sh*' }
}

function Test-SystemRunning {
  if (Get-Process llama-server -ErrorAction SilentlyContinue) { return $true }
  return [bool](Get-WebHolders)
}

function Stop-Everything {
  Log 'Stop-Everything'
  Write-Host ''
  Write-Host '--- выключение ---' -ForegroundColor Yellow
  # Держатель гасится первым: node работает у него на переднем плане и уходит
  # вместе с ним. stop-web.sh следом — на случай, если веб подняли иначе.
  if ($script:Holder -and -not $script:Holder.HasExited) {
    Stop-Process -Id $script:Holder.Id -Force -ErrorAction SilentlyContinue
  }
  # Отдельно — держатель, поднятый ДРУГИМ окном launcher'а. Ярлык один, и гасить
  # он обязан систему целиком, а не только то, что поднял сам.
  Get-WebHolders | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
  Wsl "$Repo/scripts/stop-web.sh" 2>&1 | Out-Null
  Write-Host 'веб-интерфейс остановлен'
  & "$RunDir\stop-server.ps1"
  Restore-IdleSleep
  # Уборка при выключении (web уже остановлен, поэтому можно трогать сессии):
  # сессии старше 30 дней — в архив run/archive (90 дней), вложения без ссылок,
  # лишние копии в run/backups, старые логи. Отключить: создать файл
  # F:\Harness_AI\run\cleanup-off. Правила и отчёт: scripts/dsh-cleanup.sh.
  if (-not (Test-Path "$RunDir\cleanup-off")) {
    Write-Host 'уборка...'
    Wsl "$Repo/scripts/dsh-cleanup.sh --apply --quiet" 2>&1 | Out-Null
  }
}

# Про WSL спрашиваем только в интерактивном пути и только ПОСЛЕ остановки
# харнесса. При закрытии окна крестиком спросить не у кого — тогда WSL остаётся
# жить, и это безопасный исход, а не потеря чужих процессов.
function Confirm-WslShutdown {
  Write-Host ''
  Write-Host 'Погасить также WSL? Освободит ещё ~2 ГБ, но закроет ВСЕ процессы Ubuntu' -ForegroundColor Yellow
  Write-Host 'включая Claude Code, Docker и открытые терминалы.' -ForegroundColor Yellow
  $ans = Read-Host 'Гасить WSL? [y/N]'
  if ($ans -match '^(y|Y|д|Д)') {
    Write-Host 'гашу WSL...'
    & wsl.exe --shutdown
    Write-Host 'WSL остановлен'
  } else {
    Write-Host 'WSL оставлен работать'
  }
}

# Таймауты сна по сети: STANDBYIDLE / HIBERNATEIDLE, 4-е hex-число в выводе
# powercfg /q — индекс «от сети» (мин, макс, шаг, AC, DC; порядок не зависит
# от языка системы). Секунды -> минуты для powercfg /change.
function Get-AcTimeoutMinutes([string]$setting) {
  $out = & powercfg.exe /q SCHEME_CURRENT SUB_SLEEP $setting 2>$null | Out-String
  $m = [regex]::Matches($out, '0x[0-9a-fA-F]{8}')
  if ($m.Count -lt 5) { return $null }
  return [int]([Convert]::ToInt32($m[3].Value, 16) / 60)
}

# 2026-09-14: одного SetThreadExecutionState оказалось мало — в 15:54 ПК ушёл
# в сон с причиной «System Idle» при живом запросе (powercfg /requests его
# показывал). Поэтому на время работы таймауты сна/гибернации по сети
# выставляются в 0 («никогда»), прежние значения — в power-timeouts.json,
# Restore-IdleSleep возвращает их при выключении. Если лончер умер, ПК просто
# не спит до следующего цикла старт/стоп — безопасный исход для удалённого
# доступа. Права администратора не нужны (проверено).
function Disable-IdleSleep {
  # Файл от прошлого запуска, который не дошёл до Restore (перезагрузка ПК
  # 2026-09-14 20:49 при работающем стенде), хранит НАСТОЯЩИЕ значения — его
  # не затираем, но нули выставляем всё равно: раньше здесь был return, и
  # стенд после такой перезагрузки жил с тем, что осталось в системе.
  $names = @('standby-timeout-ac', 'hibernate-timeout-ac')
  if (-not (Test-Path $PowerSaved)) {
    $saved = @{}
    foreach ($pair in @(@('STANDBYIDLE', 'standby-timeout-ac'), @('HIBERNATEIDLE', 'hibernate-timeout-ac'))) {
      $min = Get-AcTimeoutMinutes $pair[0]
      if ($null -ne $min) { $saved[$pair[1]] = $min }
    }
    if ($saved.Count -gt 0) { $saved | ConvertTo-Json | Set-Content -Encoding UTF8 $PowerSaved }
  }
  foreach ($name in $names) { & powercfg.exe /change $name 0 | Out-Null }
  Write-Host 'сон по простою отключён на время работы' -ForegroundColor DarkGray
}

function Restore-IdleSleep {
  if (-not (Test-Path $PowerSaved)) { return }
  try {
    $saved = Get-Content -Raw $PowerSaved | ConvertFrom-Json
    foreach ($p in $saved.PSObject.Properties) { & powercfg.exe /change $p.Name ([int]$p.Value) | Out-Null }
    Write-Host 'таймауты сна восстановлены'
  } catch { Write-Host "не удалось восстановить таймауты сна: $_" -ForegroundColor Yellow }
  Remove-Item -Force $PowerSaved -ErrorAction SilentlyContinue
}

# Экран загрузки: отдельный скрытый процесс с WinForms-окном (кит, стадия,
# бегунок), читает launch.status. Без него в скрытом режиме непонятно, идёт
# ли запуск. Стадии: model → web → done (окно гаснет само) | error: текст
# (окно показывает ошибку и кнопку «Закрыть»).
function Set-Stage([string]$stage) {
  if (-not $Hidden) { return }
  try { [IO.File]::WriteAllText($LaunchStatus, $stage) } catch { }
}
function Test-SplashRunning {
  return [bool](Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*harness-splash.ps1*' })
}
function Start-Splash {
  if (-not $Hidden) { return }
  if (Test-SplashRunning) { return }
  try {
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "$RunDir\harness-splash.ps1"
    ) | Out-Null
  } catch { }
}

# В скрытом режиме ошибку показывает экран загрузки (стадия error:); если его
# нет — поднимаем его заново, он покажет ошибку первым же тиком. MessageBox
# из скрытого процесса Windows прячет вместе с консолью (SW_HIDE в STARTUPINFO
# достаётся первому окну), поэтому им не пользуемся.
function Show-Error([string]$text) {
  Set-Stage ('error: ' + ($text -replace '\s+', ' '))
  Start-Splash
}

# Видеопамять после старта: свободно + кто держит (perf-counter Dedicated Usage,
# > 30 МиБ, кроме llama-server). Возвращает строку для лога или $null.
function Get-VramReport {
  try {
    $smi = "$env:SystemRoot\System32\nvidia-smi.exe"
    if (-not (Test-Path $smi)) { return $null }
    $q = (& $smi --query-gpu=memory.free,memory.used --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
    if (-not $q) { return $null }
    $free = [int]($q -split ',')[0].Trim(); $used = [int]($q -split ',')[1].Trim()
    $top = @()
    try {
      $top = (Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop).CounterSamples |
        Where-Object { $_.CookedValue -gt 30MB } |
        ForEach-Object {
          $procId = [int](($_.InstanceName -split '_')[1])
          $n = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
          if ($n -and $n -ne 'llama-server') { [pscustomobject]@{ n = $n; m = [int]($_.CookedValue / 1MB) } }
        } | Sort-Object m -Descending | Select-Object -First 4
    } catch { }
    $list = ($top | ForEach-Object { "$($_.n) $($_.m)" }) -join ', '
    return [pscustomobject]@{ free = $free; used = $used; text = "VRAM free $free MiB, used $used MiB; others: $list" }
  } catch { return $null }
}

# Скрытый режим: ждём сигнал. Возвращает 'dsh' | 'wsl' (кнопка в вебе) или
# 'gone' (систему погасил второй клик по ярлыку — гасить уже нечего).
function Wait-StopSignal {
  while ($true) {
    Start-Sleep -Seconds 2
    if (Test-Path $PowerRequest) {
      $mode = 'dsh'
      try { $mode = (Get-Content -Raw $PowerRequest | ConvertFrom-Json).mode } catch { }
      Remove-Item -Force $PowerRequest -ErrorAction SilentlyContinue
      if ($mode -notin @('wsl', 'sleep', 'shutdown')) { $mode = 'dsh' }
      Log "signal: $mode"
      return $mode
    }
    if (-not (Test-SystemRunning)) { Log 'system gone (llama-server and web holder both absent)'; return 'gone' }
  }
}

try {
  Log ('start hidden=' + $Hidden)
  Write-Host '=== Harness AI ===' -ForegroundColor Cyan

  # Ветка переключателя. Стоит ДО развёртывания .ps1: на выключении копировать
  # нечего, а лишний вызов wsl.exe только замедлил бы отклик ярлыка.
  if (Test-SystemRunning) {
    Log 'toggle: system running -> stopping'
    Write-Host 'система уже работает — этот клик её выключает' -ForegroundColor Yellow
    Stop-Everything
    # Скрытому окну спросить не у кого: второй клик гасит только харнесс,
    # WSL остаётся; выбор «с WSL» — кнопка Power в вебе.
    if (-not $Hidden) { Confirm-WslShutdown }
    Write-Host ''
    Write-Host 'Готово.' -ForegroundColor Green
    Start-Sleep -Seconds 2
    exit 0
  }

  # Правило проекта: источник .ps1 в scripts/, run/ — цель развёртывания.
  # Разворачиваем на каждом запуске, чтобы правки в репозитории не разъезжались
  # с тем, что реально исполняется (расхождение уже ловилось в bench-08).
  Wsl "cp $Repo/scripts/start-server.ps1 $Repo/scripts/stop-server.ps1 $Repo/scripts/harness-splash.ps1 $Repo/scripts/splash-whale.png /mnt/f/Harness_AI/run/"
  Remove-Item -Force $PowerRequest -ErrorAction SilentlyContinue
  Remove-Item -Force $LaunchStatus -ErrorAction SilentlyContinue
  Set-Stage 'model'
  Start-Splash

  # 1. Модель. Рука C — рабочая конфигурация решения 13, n-max=3.
  #
  # ИСТОРИЯ 2026-09-09, чтобы не искать заново. За день сервер перезапускался
  # больше десяти раз подряд, и генерация просела 83 -> 3,8 т/с при неизменной
  # командной строке. Подпись: карта «загружена» на 99 %, но потребляет 93 Вт
  # из 360, утилизация памяти 5 %, вытеснения по счётчику Non-local нет.
  # Ошибки при этом НЕ БЫЛО НИКАКОЙ — отказ молчаливый.
  #
  # Причина — накопленное состояние видеопамяти драйвера, а не конфигурация:
  # llama-server переставал получать полное выделение. Снимается ТОЛЬКО
  # перезагрузкой Windows; перезапуск сервера не помогает. После перезагрузки
  # та же тройка даёт 78,9 / 84,9 / 93,6 т/с, а llama-server держит на 164 МБ
  # больше видеопамяти при том же аппетите рабочего стола.
  #
  # Признак для диагностики: если генерация упала в разы, смотреть не логи,
  # а `nvidia-smi --query-gpu=power.draw,utilization.memory`. Низкое
  # потребление при высокой «загрузке» = это оно, помогает перезагрузка.
  Write-Host 'запускаю модель (Qwen3.8-27B, окно 64k, зрение)...'
  # Шаг 1 аудита контекста 2026-09-12: свой jinja, reasoning прошлых шагов не
  # реплеится в промпт (48-60% окна по замеру). Откат: убрать -ChatTemplateFile.
  # Обоснование и проверка — шапка параметра в start-server.ps1.
  # 2026-09-15: параметры стенда — умолчания start-server.ps1 (temp 1.0 /
  # top-p 0.95 / top-k 20 / min-p 0, шаблон qwen3.8-agent.jinja, проектор на
  # CPU, verbosity 3, n-max 3). Ручной запуск без параметров даёт тот же сервер.
  & "$RunDir\start-server.ps1" | Out-Null

  Write-Host -NoNewline 'жду готовности модели'
  $ready = $false
  foreach ($i in 1..120) {
    try {
      $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8080/health' -TimeoutSec 3 -UseBasicParsing
      if ($r.StatusCode -eq 200) { $ready = $true; break }
    } catch { }
    Write-Host -NoNewline '.'
    Start-Sleep -Seconds 1
  }
  Write-Host ''
  if (-not $ready) { throw 'модель не поднялась за 120 с, смотрите F:\Harness_AI\run\server.log' }
  Write-Host 'модель готова' -ForegroundColor Green

  # 2. Веб-интерфейс. Прежний экземпляр гасим, чтобы лог и токен были свежими.
  Wsl "$Repo/scripts/stop-web.sh" 2>&1 | Out-Null

  # Держатель: `wsl.exe` обязан оставаться живым, иначе WSL снимет веб-сервер
  # вместе с сессией. Подробнее — комментарий в start-web.sh.
  #
  # Аргументов у harness-web-fg.sh нет намеренно: Start-Process склеивает
  # ArgumentList пробелами без кавычек, и составная команда доезжает рваной.
  Write-Host 'запускаю веб-интерфейс...'
  Set-Stage 'web'
  $Holder = Start-Process wsl.exe -PassThru -WindowStyle Hidden -ArgumentList @(
    '-d', $Distro, '--', 'bash', '-lc', 'bash "$HOME/Harness_AI/scripts/harness-web-fg.sh"'
  )

  $url = $null
  foreach ($i in 1..40) {
    Start-Sleep -Seconds 1
    if ($Holder.HasExited) { throw 'веб-интерфейс упал при старте, смотрите ~/Harness_AI/run/web.log' }
    $line = Wsl "grep -h 'dsh web:' $WebLog 2>/dev/null | tail -1"
    if ($line -match '(http://\S+)') { $url = $Matches[1]; break }
  }
  if (-not $url) { throw 'не дождался ссылки за 40 с, смотрите ~/Harness_AI/run/web.log' }

  Write-Host 'веб-интерфейс готов' -ForegroundColor Green
  Write-Host ''
  Write-Host "  $url" -ForegroundColor Cyan
  Write-Host '  (токен одноразовый, меняется при каждом запуске)'
  Write-Host ''
  $vram = Get-VramReport
  if ($vram) { Log $vram.text }
  if ($vram -and $vram.free -lt $VramWarnMiB) {
    Set-Stage ("warn: свободно $($vram.free) МиБ видеопамяти (порог $VramWarnMiB): генерация может уйти в ОЗУ и замедлиться в разы. Держат: " + (($vram.text -split 'others: ')[1]))
  } else {
    Set-Stage 'done'
  }
  Log 'ready'
  if (-not $NoBrowser) { Start-Process $url }

  # Пока это окно живо, ПК не уходит в сон: ES_CONTINUOUS|ES_SYSTEM_REQUIRED
  # (2147483649 = 0x80000001; hex-литерал PS 5.1 в UInt32 не приводит).
  # ES_DISPLAY_REQUIRED не ставится — монитор гаснет по расписанию Windows
  # (5 мин), а машина остаётся доступной телефону через туннель. Флаг живёт
  # на этом потоке до выхода из скрипта — снимать не нужно ни по Enter, ни по
  # ошибке. Без него через 30 мин простоя (standby-timeout-ac 0x708) ПК
  # засыпает, и запрос с телефона приходит в никуда; разбудить через туннель
  # нельзя. Проверка: powercfg /requests (от администратора) показывает
  # SYSTEM: powershell.exe.
  try {
    Add-Type -Namespace DshPower -Name Native -MemberDefinition '[DllImport("kernel32.dll", SetLastError=true)] public static extern uint SetThreadExecutionState(uint esFlags);'
    [void][DshPower.Native]::SetThreadExecutionState([uint32]2147483649)
    Write-Host 'сон ПК заблокирован на время работы; монитор гаснет как обычно' -ForegroundColor DarkGray
  } catch {
    Write-Host "не удалось заблокировать сон ПК: $_" -ForegroundColor Yellow
  }
  try { Disable-IdleSleep } catch { Write-Host "не удалось отключить таймауты сна: $_" -ForegroundColor Yellow }

  if ($Hidden) {
    $mode = Wait-StopSignal
    if ($mode -eq 'gone') {
      Write-Host 'система выключена другим окном'
    } else {
      Stop-Everything
      # wsl: только погасить Ubuntu. sleep: сон ПК (WSL оставляем — после
      # пробуждения всё на месте). shutdown: полное выключение, Ubuntu гасим
      # заранее, чтобы Windows не ждала VM; 5 с задержки — на выход скрипта.
      switch ($mode) {
        'wsl'      { & wsl.exe --shutdown }
        'sleep'    {
          Add-Type -AssemblyName System.Windows.Forms
          [void][System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false)
        }
        'shutdown' {
          & wsl.exe --shutdown
          & shutdown.exe /s /t 5 /c 'Harness AI: shutdown requested from the web UI'
        }
      }
    }
  } else {
    Write-Host 'Система работает. Это окно ею управляет — не закрывайте его во время работы.'
    Write-Host 'Выключить можно и отсюда, и вторым кликом по тому же ярлыку.'
    Write-Host ''
    Read-Host 'Нажмите Enter, чтобы выключить систему'

    # Систему мог погасить второй клик по ярлыку, пока это окно ждало Enter.
    # Тогда гасить нечего и спрашивать про WSL не за чем.
    if (Test-SystemRunning) {
      Stop-Everything
      Confirm-WslShutdown
    } else {
      Write-Host 'система уже выключена другим окном'
    }
  }

  Write-Host ''
  Write-Host 'Готово.' -ForegroundColor Green
  Log 'exit'
  Start-Sleep -Seconds 2
}
catch {
  Write-Host ''
  Write-Host "ОШИБКА: $_" -ForegroundColor Red
  Log "ERROR: $_"
  try { Stop-Everything } catch { }
  if ($Hidden) { Show-Error "$_ (лог: ~/Harness_AI/run/web.log)"; exit 1 }
  Write-Host ''
  Read-Host 'Нажмите Enter, чтобы закрыть окно'
  exit 1
}
