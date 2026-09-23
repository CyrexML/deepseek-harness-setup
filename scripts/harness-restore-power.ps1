# Restore the sleep timeouts after a reboot that happened while the stand ran.
#
# The launcher sets standby/hibernate-timeout-ac to 0 through `powercfg /change`
# for the duration - a PERSISTENT power scheme setting - so if Windows rebooted on
# its own the PC would stay sleepless until the launcher's next stop. The
# "Harness AI power restore" scheduled task runs this at logon and every 15
# minutes: when power-timeouts.json exists and no launcher is running, the saved
# values go back and the file is removed. While the launcher lives this touches
# nothing; it restores them itself on shutdown.
param([string]$Saved = 'F:\Harness_AI\run\power-timeouts.json')
$RunDir = Split-Path -Parent $Saved
$LauncherLog = "$RunDir\launcher.log"
function Log([string]$m) { try { Add-Content -Path $LauncherLog -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " [restore-power] " + $m) } catch { } }

if (-not (Test-Path $Saved)) { exit 0 }
$launcher = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
  Where-Object { $_.CommandLine -like '*harness-start.ps1*' }
if ($launcher) { Log 'saved timeouts present, launcher running — leaving them to it'; exit 0 }

# The stand may have been started straight from WSL, with no launcher at all, and
# sleep still has to stay off - otherwise this task would restore the timeouts 15
# minutes later and Windows would sleep mid-run. A live stand is detected by its
# interface port: WSL2 forwards listening ports to 127.0.0.1 on the Windows side,
# so the check works from here.
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
