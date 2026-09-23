# Возврат таймаутов сна после перезагрузки, случившейся во время работы стенда.
#
# Лончер (harness-start.ps1) на время работы ставит standby/hibernate-timeout-ac
# в 0 через `powercfg /change` — это ПОСТОЯННАЯ настройка схемы питания, и если
# Windows перезагрузилась сама (обновление, ночь на 2026-09-15), ПК после входа
# остаётся без сна до следующего Stop лончера. Этот скрипт запускается задачей
# планировщика «Harness AI power restore» при входе пользователя (задержка 30 с,
# см. install-shortcuts.ps1): если лежит power-timeouts.json и лончер не
# работает — вернуть сохранённые значения и убрать файл. Пока лончер жив,
# ничего не трогает (он сам восстановит при остановке).
param([string]$Saved = 'F:\Harness_AI\run\power-timeouts.json')
$RunDir = Split-Path -Parent $Saved
$LauncherLog = "$RunDir\launcher.log"
function Log([string]$m) { try { Add-Content -Path $LauncherLog -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " [restore-power] " + $m) } catch { } }

if (-not (Test-Path $Saved)) { exit 0 }
$launcher = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
  Where-Object { $_.CommandLine -like '*harness-start.ps1*' }
if ($launcher) { Log 'saved timeouts present, launcher running — leaving them to it'; exit 0 }

# Стенд могли поднять напрямую из WSL (scripts/start-web.sh) — тогда лончера
# нет, но сон глушить всё равно надо, иначе эта задача через 15 минут вернёт
# таймауты и Windows уснёт посреди работы агента (так и было 2026-09-23).
# Признак живого стенда: отвечает порт интерфейса. WSL2 пробрасывает свои
# слушающие порты на 127.0.0.1 Windows, поэтому проверка работает отсюда.
$WebPort = if ($env:DSH_WEB_PORT) { [int]$env:DSH_WEB_PORT } else { 3080 }
$webAlive = $false
try {
  $client = New-Object Net.Sockets.TcpClient
  $webAlive = $client.ConnectAsync('127.0.0.1', $WebPort).Wait(700)
  $client.Close()
} catch { $webAlive = $false }
if ($webAlive) { Log ("saved timeouts present, DSH web answers on port $WebPort — leaving them to it"); exit 0 }
try {
  $s = Get-Content -Raw $Saved | ConvertFrom-Json
  foreach ($p in $s.PSObject.Properties) { & powercfg.exe /change $p.Name ([int]$p.Value) | Out-Null }
  Remove-Item -Force $Saved -ErrorAction SilentlyContinue
  Log ('restored after unclean stop: ' + (($s.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '))
} catch { Log "restore failed: $_" }
