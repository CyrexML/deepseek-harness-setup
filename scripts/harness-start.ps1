# Single entry point to the Harness AI stand: model + dsh web interface.
# One shortcut, and it is a TOGGLE: a click starts the system when it is down
# and stops it when it is running.
#
# Start order is not arbitrary: llama-server comes FIRST, because start-web.sh
# refuses to start while the model does not answer. llama-server is deliberately
# tied to this window, so closing the window also kills the model even if the
# cleanup never ran.
#
# -Hidden is the shortcut mode (through harness-launch.vbs): no console, and
# instead of Enter the script waits for the power.request signal file written by
# the Power button in the web UI, or for a second click on the shortcut.
param([switch]$NoBrowser, [switch]$Hidden)

$ErrorActionPreference = 'Stop'
chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8

# These scripts are copied into <windowsRoot>\run, so the script's OWN folder is
# RunDir. The author's F: used to be baked in here and nothing substituted it at
# install time - so on any other drive the launcher looked for its files where
# they were not, and silently did nothing at all.
$RunDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
# Written next to these scripts by 40-shortcuts.ps1, for the same reason.
$Distro = if (Test-Path "$RunDir\distro.txt") { (Get-Content -Raw "$RunDir\distro.txt").Trim() } else { 'Ubuntu' }
# The same folder as WSL sees it: D:\Harness_AI\run -> /mnt/d/Harness_AI/run.
# The copy step below used to name /mnt/f outright, so on any other drive the
# launcher refreshed its own files into a folder that was not there.
$RunWsl = '/mnt/' + $RunDir.Substring(0, 1).ToLower() + ($RunDir.Substring(2) -replace '\\', '/')

# Message language: HARNESS_LANG, else run\lang.txt written at install time,
# else English. Translations are a table of "English string -> translation" in
# run\i18n\<lang>.json; a missing string is printed as it is.
$Lang = if ($env:HARNESS_LANG) { $env:HARNESS_LANG }
        elseif (Test-Path "$RunDir\lang.txt") { (Get-Content -Raw "$RunDir\lang.txt").Trim() }
        else { 'en' }
$I18n = @{}
if ($Lang -and $Lang -ne 'en' -and (Test-Path "$RunDir\i18n\$Lang.json")) {
  try {
    (Get-Content "$RunDir\i18n\$Lang.json" -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
      ForEach-Object { $I18n[$_.Name] = [string]$_.Value }
  } catch { }
}
function T { param([string]$Text, [object[]]$Values)
  $fmt = if ($I18n.ContainsKey($Text)) { $I18n[$Text] } else { $Text }
  if ($Values -and $Values.Count -gt 0) { [string]::Format($fmt, $Values) } else { $fmt }
}
# VRAM warning threshold after start (MiB). A 64k window normally leaves ~250
# MiB free; below that the driver silently spills weights into RAM and
# generation drops about tenfold. Who else holds VRAM is logged on every start.
$VramWarnMiB = 100
$Repo   = '~/Harness_AI'
$WebLog = "$Repo/run/web.log"
$Holder = $null
# Signal file from the bridge (Settings -> Remote access -> Power):
# {"mode":"dsh"|"wsl"}. Same path as DSH_POWER_REQUEST_FILE in start-web.sh.
$PowerRequest = "$RunDir\power.request"
# Sleep timeouts saved for the duration of the run (see Disable-IdleSleep).
$PowerSaved = "$RunDir\power-timeouts.json"
# Launch stages for the splash screen (harness-splash.ps1) in hidden mode.
$LaunchStatus = "$RunDir\launch.status"
# Launcher log: in hidden mode this is the only trace of what happened.
$LauncherLog = "$RunDir\launcher.log"
# Rotated past 1 MB into launcher.log.1.
function Log([string]$m) {
  try {
    if ((Test-Path $LauncherLog) -and (Get-Item $LauncherLog).Length -gt 1MB) { Move-Item -Force $LauncherLog "$LauncherLog.1" }
    Add-Content -Path $LauncherLog -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " [$PID] " + $m)
  } catch { }
}

# Any stderr from a native command is a TERMINATING error here the moment it is
# redirected - and every caller below pipes `2>&1 | Out-Null`. $ErrorActionPreference
# is 'Stop', so PowerShell wraps the first stderr line into a NativeCommandError.
# A shell script that merely WARNED then killed the launcher: a stand with no
# sessions yet made `find` print "No such file or directory" during the shutdown
# cleanup, and the window closed with "Could not start: find: ...". The trap is
# lifted for the call itself; callers that care about success check $LASTEXITCODE.
function Wsl([string]$cmd) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & wsl.exe -d $Distro -- bash -lc $cmd } finally { $ErrorActionPreference = $prev }
}

# The holder is the `wsl.exe` that started harness-web-fg.sh: node runs in its
# foreground, which makes the system visible from any other window.
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
  Write-Host (T '--- shutting down ---') -ForegroundColor Yellow
  # Kill the holder first: node runs in its foreground and dies with it.
  # stop-web.sh follows, in case the web was started some other way.
  if ($script:Holder -and -not $script:Holder.HasExited) {
    Stop-Process -Id $script:Holder.Id -Force -ErrorAction SilentlyContinue
  }
  # Also holders started by ANOTHER launcher window: there is one shortcut, and
  # it must stop the whole system, not only what it started itself.
  Get-WebHolders | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
  Wsl "$Repo/scripts/stop-web.sh" 2>&1 | Out-Null
  Write-Host (T 'web interface stopped')
  & "$RunDir\stop-server.ps1"
  Restore-IdleSleep
  # Cleanup on shutdown (safe now that the web is stopped): old sessions are
  # archived, unreferenced attachments and stale backups removed. Disable by
  # creating <run>\cleanup-off; rules live in scripts/dsh-cleanup.sh.
  if (-not (Test-Path "$RunDir\cleanup-off")) {
    Write-Host (T 'cleaning up...')
    Wsl "$Repo/scripts/dsh-cleanup.sh --apply --quiet" 2>&1 | Out-Null
  }
}

# WSL is only offered on the interactive path and only AFTER the harness has
# stopped. When the window is closed there is nobody to ask, and leaving WSL
# running is the safe outcome rather than killing someone else's processes.
function Confirm-WslShutdown {
  Write-Host ''
  Write-Host (T 'Stop WSL as well? Frees another ~2 GB but closes ALL Ubuntu processes,') -ForegroundColor Yellow
  Write-Host (T 'including editors, Docker and open terminals.') -ForegroundColor Yellow
  $ans = Read-Host (T 'Stop WSL? [y/N]')
  if ($ans -match '^(y|Y)') {
    Write-Host (T 'stopping WSL...')
    & wsl.exe --shutdown
    Write-Host (T 'WSL stopped')
  } else {
    Write-Host (T 'WSL left running')
  }
}

# AC sleep timeouts: STANDBYIDLE / HIBERNATEIDLE. The 4th hex number in
# powercfg /q output is the AC value (min, max, step, AC, DC - the order does
# not depend on the system language). Seconds -> minutes for powercfg /change.
function Get-AcTimeoutMinutes([string]$setting) {
  $out = & powercfg.exe /q SCHEME_CURRENT SUB_SLEEP $setting 2>$null | Out-String
  $m = [regex]::Matches($out, '0x[0-9a-fA-F]{8}')
  if ($m.Count -lt 5) { return $null }
  return [int]([Convert]::ToInt32($m[3].Value, 16) / 60)
}

# SetThreadExecutionState alone turned out not to be enough: the PC still slept
# with reason "System Idle" while a request was live. So while the stand runs the
# AC sleep and hibernate timeouts are set to 0 ("never"), the previous values go
# into power-timeouts.json, and Restore-IdleSleep puts them back on shutdown.
# If the launcher dies the PC simply does not sleep until the next start/stop
# cycle - the safe outcome for remote access. No administrator rights needed.
function Disable-IdleSleep {
  # A file left by a previous run that never reached Restore (a reboot while the
  # stand was up) holds the REAL values: keep it, but write the zeros anyway. An
  # early return here used to leave the stand running with whatever the system
  # had after such a reboot.
  $names = @('standby-timeout-ac', 'hibernate-timeout-ac')
  if (-not (Test-Path $PowerSaved)) {
    $saved = @{}
    foreach ($pair in @(@('STANDBYIDLE', 'standby-timeout-ac'), @('HIBERNATEIDLE', 'hibernate-timeout-ac'))) {
      $min = Get-AcTimeoutMinutes $pair[0]
      # Same guard as harness-idle-sleep.ps1: a standby timeout that already
      # reads "never" is our own leftover, not the user's choice. Saved as the
      # original it would be "restored" on every stop and the PC would never
      # sleep again. Hibernate "never" is an ordinary setting and is kept.
      if ($pair[1] -eq 'standby-timeout-ac' -and $min -eq 0) {
        $min = 10
        Log "standby timeout read as 'never' - recording 10 min as the value to restore"
      }
      if ($null -ne $min) { $saved[$pair[1]] = $min }
    }
    if ($saved.Count -gt 0) { $saved | ConvertTo-Json | Set-Content -Encoding UTF8 $PowerSaved }
  }
  foreach ($name in $names) { & powercfg.exe /change $name 0 | Out-Null }
  Write-Host (T 'idle sleep disabled while the stand runs') -ForegroundColor DarkGray
}

function Restore-IdleSleep {
  if (-not (Test-Path $PowerSaved)) { return }
  try {
    $saved = Get-Content -Raw $PowerSaved | ConvertFrom-Json
    foreach ($p in $saved.PSObject.Properties) { & powercfg.exe /change $p.Name ([int]$p.Value) | Out-Null }
    Write-Host (T 'sleep timeouts restored')
    Log ('sleep timeouts restored: ' + (($saved.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', '))
  } catch {
    Write-Host (T 'could not restore the sleep timeouts: {0}' @($_)) -ForegroundColor Yellow
    Log "sleep timeouts restore FAILED: $_"
  }
  Remove-Item -Force $PowerSaved -ErrorAction SilentlyContinue
}

# Splash: a separate hidden process with a WinForms window that reads
# launch.status. Without it a hidden launch gives no sign of progress. Stages:
# model -> web -> done (the window fades out), stopping -> stopped, or
# "error: text" (the window shows the error and a close button).
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

# In hidden mode errors are shown by the splash (stage "error:"); if it is gone
# it is started again and shows the error on its first tick. A MessageBox is no
# use here: Windows hides it together with the console (SW_HIDE from STARTUPINFO
# lands on the first window).
function Show-Error([string]$text) {
  Set-Stage ('error: ' + ($text -replace '\s+', ' '))
  Start-Splash
}

# VRAM after start: free memory plus who else holds it (Dedicated Usage counter,
# above 30 MiB, excluding llama-server). Returns a log line or $null.
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

# --- GPU watchdog and model restart (2026-10-14) ---------------------------
#
# The "stuck GPU" state: generation falls from ~70-130 to ~14-23 tok/s with no
# error. Signature, measured 2026-10-14 during generation: utilization.gpu
# 97-100% at full SM clock, but utilization.memory 13-14% and ~119 W, against
# ~65% and ~325 W when healthy - the card waits instead of streaming weights.
# Restarting ONLY llama-server cured it (22.7 -> 131 tok/s) with DSH, sessions
# and the tunnel left running; no Windows reboot was needed. The trigger is not
# known yet (a headless Chromium run was ruled out).
#
# So, while the stand runs in hidden mode, every ~6 s during generation the
# counters are sampled; ~30 s of the stuck signature schedules a model restart
# for the next pause between requests (or after 120 s regardless). DSH retries
# a request while the model is down (qwen-local retryPolicy, ~45 s). If the
# restart does not help - stuck again within 10 min twice, or 3 auto restarts
# in an hour - auto restart stops and the status says a PC reboot is needed.
# The web Power menu shows the status (run\gpu.status) and has a manual
# "Restart the model" button (signal mode 'model').
$GpuStatusFile = "$RunDir\gpu.status"
$GpuStuckSamples = 5            # x ~6 s = ~30 s of stuck generation
$script:Gpu = @{ streak = 0; pendingSince = $null; auto = New-Object System.Collections.ArrayList
  lastRestart = $null; persistent = $false; failedFix = 0; last = $null; state = $null }

function Test-ModelBusy {
  try { $s = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/slots' -TimeoutSec 2; return [bool](@($s) | Where-Object { $_.is_processing }) }
  catch { return $false }
}

function Get-GpuLoad {
  try {
    $q = (& "$env:SystemRoot\System32\nvidia-smi.exe" --query-gpu=utilization.gpu,utilization.memory,power.draw,memory.free --format=csv,noheader,nounits 2>$null | Select-Object -First 1)
    if (-not $q) { return $null }
    $p = $q -split ','
    $inv = [Globalization.CultureInfo]::InvariantCulture
    return [pscustomobject]@{ gpu = [int]$p[0].Trim(); mem = [int]$p[1].Trim(); watts = [double]::Parse($p[2].Trim(), $inv); free = [int]$p[3].Trim() }
  } catch { return $null }
}

function Write-GpuStatus($load, [bool]$busy) {
  try {
    $g = $script:Gpu
    $state = if ($g.state) { $g.state } elseif ($g.persistent) { 'reboot-needed' } elseif ($g.pendingSince) { 'restart-pending' } elseif ($g.last -and -not $g.last.healthy) { 'stuck' } elseif ($g.last) { 'ok' } else { 'unknown' }
    $o = [ordered]@{
      checked = (Get-Date).ToString('o'); state = $state; busy = $busy
      now = $(if ($load) { [ordered]@{ gpu = $load.gpu; mem = $load.mem; watts = $load.watts; free = $load.free } } else { $null })
      lastGeneration = $g.last
      lastRestart = $(if ($g.lastRestart) { [ordered]@{ at = $g.lastRestart.at.ToString('o'); reason = $g.lastRestart.reason; ok = $g.lastRestart.ok } } else { $null })
      autoRestartsLastHour = @($g.auto | Where-Object { $_ -gt (Get-Date).AddHours(-1) }).Count
    }
    # WriteAllText: no BOM (Set-Content -Encoding UTF8 writes one, and JSON.parse rejects it).
    [IO.File]::WriteAllText($GpuStatusFile, ($o | ConvertTo-Json -Compress -Depth 4))
  } catch { }
}

function Restart-Model([string]$reason) {
  $g = $script:Gpu
  $auto = $reason -like 'auto*'
  Log "model restart ($reason)"
  $g.pendingSince = $null; $g.streak = 0; $g.last = $null
  if ($auto) { [void]$g.auto.Add((Get-Date)) } else { $g.persistent = $false; $g.failedFix = 0 }
  $g.state = 'restarting'; Write-GpuStatus $null $false
  try { & "$RunDir\stop-server.ps1" | Out-Null } catch { Log "stop-server: $_" }
  Start-Sleep -Seconds 2
  $ok = $false
  try {
    & "$RunDir\start-server.ps1" | Out-Null
    foreach ($i in 1..120) {
      try { $r = Invoke-WebRequest -Uri 'http://127.0.0.1:8080/health' -TimeoutSec 3 -UseBasicParsing; if ($r.StatusCode -eq 200) { $ok = $true; break } } catch { }
      Start-Sleep -Seconds 1
    }
  } catch { Log "start-server: $_" }
  $g.state = $null
  $g.lastRestart = @{ at = Get-Date; reason = $reason; ok = $ok; auto = $auto }
  Log ('model restart ' + $(if ($ok) { 'done' } else { 'FAILED: no /health in 120 s' }))
  $v = Get-VramReport; if ($v) { Log $v.text }
  Write-GpuStatus $null $false
}

function Watch-Gpu([int]$tick) {
  $g = $script:Gpu
  $busy = Test-ModelBusy
  if ($g.pendingSince) {
    $waited = ((Get-Date) - $g.pendingSince).TotalSeconds
    if (-not $busy) { Restart-Model 'auto'; return }
    if ($waited -gt 120) { Restart-Model 'auto, no pause in 120 s'; return }
  }
  if ($tick % 3 -ne 0) { return }
  $load = Get-GpuLoad
  if ($load -and $busy) {
    $stuck = ($load.gpu -ge 80 -and $load.mem -lt 30 -and $load.watts -lt 200)
    $g.last = [ordered]@{ at = (Get-Date).ToString('o'); healthy = (-not $stuck); gpu = $load.gpu; mem = $load.mem; watts = $load.watts }
    if ($stuck) { $g.streak++ } else { $g.streak = 0 }
    if ($stuck -and $g.streak -eq $GpuStuckSamples) {
      Log "GPU stuck for ~30 s: util $($load.gpu)%, memory bus $($load.mem)%, $($load.watts) W"
      $recent = $g.lastRestart -and $g.lastRestart.auto -and ((Get-Date) - $g.lastRestart.at).TotalMinutes -lt 10
      if ($recent) { $g.failedFix++ } else { $g.failedFix = 0 }
      $hour = @($g.auto | Where-Object { $_ -gt (Get-Date).AddHours(-1) }).Count
      if ($g.failedFix -ge 2 -or $hour -ge 3) {
        if (-not $g.persistent) { Log 'stuck again right after model restarts: auto restart off, a PC reboot is needed' }
        $g.persistent = $true
      } elseif (-not $g.pendingSince) {
        $g.pendingSince = Get-Date
        Log 'model restart scheduled for the next pause between requests'
      }
    }
  }
  Write-GpuStatus $load $busy
}

# Hidden mode: wait for a signal. Returns 'dsh' | 'wsl' | 'sleep' | 'shutdown'
# (the web Power menu) or 'gone' (a second click on the shortcut already stopped
# the system). Mode 'model' restarts only llama-server and keeps waiting.
function Wait-StopSignal {
  $tick = 0
  while ($true) {
    Start-Sleep -Seconds 2
    $tick++
    if (Test-Path $PowerRequest) {
      $mode = 'dsh'
      try { $mode = (Get-Content -Raw $PowerRequest | ConvertFrom-Json).mode } catch { }
      Remove-Item -Force $PowerRequest -ErrorAction SilentlyContinue
      if ($mode -eq 'model') { Log 'signal: model'; Restart-Model 'button'; continue }
      if ($mode -notin @('wsl', 'sleep', 'shutdown')) { $mode = 'dsh' }
      Log "signal: $mode"
      return $mode
    }
    if (-not (Test-SystemRunning)) { Log 'system gone (llama-server and web holder both absent)'; return 'gone' }
    try { Watch-Gpu $tick } catch { Log "gpu watchdog: $_" }
  }
}

# One click, one launcher.
#
# A DOUBLE click - which is what most people give a shortcut - started two copies
# in the same second. Both looked at Test-SystemRunning before either had started
# anything, both saw nothing, both went on to start, and they collided on
# server.pid and server.log. What the person saw was "could not start", naming a
# file rather than the second copy of itself.
#
# The lock is held for the START PHASE ONLY and released once the system is up,
# so a LATER click still stops everything - the toggle is the whole point of this
# shortcut.
$script:StartLock = $null
$script:HaveStartLock = $true
try {
  $script:StartLock = New-Object System.Threading.Mutex($false, 'Global\HarnessAiLauncherStart')
  $script:HaveStartLock = $script:StartLock.WaitOne(0)
} catch {
  # A mutex we cannot create must never be a reason not to start.
  $script:HaveStartLock = $true
}
function Release-StartLock {
  if ($script:StartLock -and $script:HaveStartLock) {
    try { $script:StartLock.ReleaseMutex() } catch { }
    $script:HaveStartLock = $false
  }
}

try {
  Log ('start hidden=' + $Hidden)
  if (-not $script:HaveStartLock) {
    Log 'another launcher is still starting - this click is ignored (double click?)'
    exit 0
  }
  Write-Host '=== Harness AI ===' -ForegroundColor Cyan

  # Toggle branch, before deploying the .ps1 files: a shutdown has nothing to
  # copy, and an extra wsl.exe call would only slow the shortcut down.
  #
  # The splash is shown here on purpose. Launched from the shortcut the console
  # is hidden, so without it a click on a running system stopped everything in
  # complete silence and looked exactly like "the launcher does not work".
  if (Test-SystemRunning) {
    Log 'toggle: system running -> stopping'
    Write-Host (T 'the system is already running - this click stops it') -ForegroundColor Yellow
    Set-Stage 'stopping'
    Start-Splash
    Stop-Everything
    Set-Stage 'stopped'
    # A hidden window has nobody to ask: a second click stops the harness only
    # and leaves WSL running; "with WSL" is the Power button in the web UI.
    if (-not $Hidden) { Confirm-WslShutdown }
    Write-Host ''
    Write-Host (T 'Done.') -ForegroundColor Green
    Start-Sleep -Seconds 2
    exit 0
  }

  # Project rule: scripts/ is the source, run/ is the deployment target. Copy on
  # every start so what executes cannot drift from the repository (drift was
  # caught once in bench-08, and again on 2026-09-24: the deployed launcher was
  # nine days old because it was the one file that copied itself nowhere).
  # harness-start.ps1 is included: PowerShell has already read it into memory, so
  # replacing the file mid-run is safe and the NEXT click gets the fresh code.
  # start-server.ps1 and stop-server.ps1 are NOT in this list, and must not be:
  # they are generated per machine by 30-tune.ps1 from templates/, with this
  # machine's root substituted. Copying the repository's own copies over them
  # replaced a correct D:\ with the author's F:\ on every single start, and the
  # launcher then reported a missing llama-server.exe on a drive that is not there.
  Wsl "cp $Repo/scripts/harness-splash.ps1 $Repo/scripts/splash-whale.png $Repo/scripts/harness-start.ps1 $Repo/scripts/harness-stop.ps1 $RunWsl/"
  # Message catalogs travel with the scripts, otherwise a Russian launcher would
  # fall back to English after every update.
  Wsl "mkdir -p $RunWsl/i18n && cp $Repo/i18n/*.json $RunWsl/i18n/ 2>/dev/null || true"
  Remove-Item -Force $PowerRequest -ErrorAction SilentlyContinue
  Remove-Item -Force $LaunchStatus -ErrorAction SilentlyContinue
  Set-Stage 'model'
  Start-Splash

  # 1. The model.
  #
  # Diagnostic note worth keeping: generation can collapse (83 -> 3.8 tok/s once,
  # 70 -> 14 and 131 -> 22.7 later) with an unchanged command line and no error.
  # The signature is a card reported as ~99% "busy" while drawing ~100-120 W of
  # 360 with 5-14% memory utilisation. This note used to say only a Windows
  # reboot clears it; on 2026-10-14 restarting ONLY llama-server did (22.7 ->
  # 131 tok/s). The watchdog in Wait-StopSignal now detects it and restarts the
  # model; the Power menu has a manual button. See "GPU watchdog" above.
  Write-Host (T 'starting the model...')
  # Sampling and the chat template are the defaults of start-server.ps1; the
  # custom jinja keeps past reasoning out of the replayed prompt (measured at
  # 48-60% of the window). Roll back by dropping -ChatTemplateFile.
  & "$RunDir\start-server.ps1" | Out-Null

  Write-Host -NoNewline (T 'waiting for the model')
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
  if (-not $ready) { throw (T 'the model did not come up in 120 s, see {0}\server.log' @($RunDir)) }
  Write-Host (T 'model ready') -ForegroundColor Green

  # 2. The web interface. Stop any previous instance so the log and the token
  # are fresh.
  Wsl "$Repo/scripts/stop-web.sh" 2>&1 | Out-Null

  # The holder `wsl.exe` must stay alive, otherwise WSL tears the web server down
  # with the session (see the comment in start-web.sh).
  Write-Host (T 'starting the web interface...')
  Set-Stage 'web'

  # The old URL must not be mistaken for the new one: the wait below greps
  # web.log for "dsh web:", and a line left by the previous run would make a
  # failed start look successful (seen on 2026-09-24).
  Wsl ": > $WebLog"

  # Absolute path, resolved once: Start-Process joins ArgumentList with spaces
  # and quotes nothing, so the arguments must survive as separate tokens with no
  # shell expansion - `bash -lc '...'` arrives torn apart, and a bare `~` never
  # expands without a shell.
  $wslHome = (& wsl.exe -d $Distro -- bash -lc 'printf %s "$HOME"')
  if (-not $wslHome -or $wslHome -match '\s') { throw (T 'could not resolve the WSL home directory: {0}' @($wslHome)) }
  $Holder = Start-Process wsl.exe -PassThru -WindowStyle Hidden -ArgumentList @(
    '-d', $Distro, '--', 'bash', "$wslHome/Harness_AI/scripts/harness-web-fg.sh"
  )

  $url = $null
  foreach ($i in 1..40) {
    Start-Sleep -Seconds 1
    if ($Holder.HasExited) { throw (T 'the web interface died on start, see ~/Harness_AI/run/web.log') }
    $line = Wsl "grep -h 'dsh web:' $WebLog 2>/dev/null | tail -1"
    if ($line -match '(http://\S+)') { $url = $Matches[1]; break }
  }
  if (-not $url) { throw (T 'no link after 40 s, see ~/Harness_AI/run/web.log') }

  Write-Host (T 'web interface ready') -ForegroundColor Green
  Write-Host ''
  Write-Host "  $url" -ForegroundColor Cyan
  Write-Host (T '  (the token is single-use and changes on every start)')
  Write-Host ''
  $vram = Get-VramReport
  if ($vram) { Log $vram.text }
  if ($vram -and $vram.free -lt $VramWarnMiB) {
    Set-Stage ('warn: ' + (T 'only {0} MiB of VRAM free (threshold {1}): generation may spill into RAM and slow down several times over. Held by: {2}' @($vram.free, $VramWarnMiB, (($vram.text -split 'others: ')[1]))))
  } else {
    Set-Stage 'done'
  }
  Log 'ready'
  # The start phase is over: from here a click is a deliberate second one and
  # must be allowed through to stop the system.
  Release-StartLock
  if (-not $NoBrowser) { Start-Process $url }

  # While this window lives the PC does not sleep: ES_CONTINUOUS|ES_SYSTEM_REQUIRED
  # (2147483649 = 0x80000001; PS 5.1 will not cast the hex literal to UInt32).
  # ES_DISPLAY_REQUIRED is deliberately NOT set: the monitor still turns off on
  # the Windows schedule while the machine stays reachable from a phone. The flag
  # lives on this thread until the script exits. Verify with powercfg /requests.
  try {
    Add-Type -Namespace DshPower -Name Native -MemberDefinition '[DllImport("kernel32.dll", SetLastError=true)] public static extern uint SetThreadExecutionState(uint esFlags);'
    [void][DshPower.Native]::SetThreadExecutionState([uint32]2147483649)
    Write-Host (T 'PC sleep is blocked while the stand runs; the monitor still turns off as usual') -ForegroundColor DarkGray
  } catch {
    Write-Host (T 'could not block PC sleep: {0}' @($_)) -ForegroundColor Yellow
  }
  try { Disable-IdleSleep } catch { Write-Host (T 'could not disable the sleep timeouts: {0}' @($_)) -ForegroundColor Yellow }

  if ($Hidden) {
    $mode = Wait-StopSignal
    if ($mode -eq 'gone') {
      Write-Host (T 'the system was stopped by another window')
      # Usually another launcher stopped it and restored the timeouts already, in
      # which case this is a no-op. But "gone" also covers a model and web that
      # simply died, and then nobody restored anything: the scheduled task would
      # get to it within fifteen minutes, and the PC would not sleep until then.
      Restore-IdleSleep
    } else {
      Stop-Everything
      # wsl: stop Ubuntu only. sleep: suspend the PC and leave WSL alone, so
      # everything is in place after waking. shutdown: stop Ubuntu first so
      # Windows does not wait for the VM, with 5 s for this script to exit.
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
    Write-Host (T 'The system is running. This window controls it - keep it open.')
    Write-Host (T 'You can stop it from here, or with a second click on the same shortcut.')
    Write-Host ''
    Read-Host (T 'Press Enter to stop the system')

    # A second click on the shortcut may have stopped the system while this
    # window waited for Enter; then there is nothing to stop or to ask about.
    if (Test-SystemRunning) {
      Stop-Everything
      Confirm-WslShutdown
    } else {
      Write-Host (T 'the system was already stopped by another window')
    }
  }

  Write-Host ''
  Write-Host (T 'Done.') -ForegroundColor Green
  Log 'exit'
  Start-Sleep -Seconds 2
}
catch {
  Write-Host ''
  Write-Host (T 'ERROR: {0}' @($_)) -ForegroundColor Red
  Log "ERROR: $_"
  try { Stop-Everything } catch { }
  if ($Hidden) { Show-Error (T '{0} (log: ~/Harness_AI/run/web.log)' @($_)); exit 1 }
  Write-Host ''
  Read-Host (T 'Press Enter to close this window')
  exit 1
}
