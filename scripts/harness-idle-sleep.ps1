# Idle-sleep suppressor for a stand started WITHOUT the launcher.
#
# harness-start.ps1 sets standby/hibernate-timeout-ac to 0 for the duration and
# restores the previous values on stop. But the stand can also be started
# straight from WSL, and then the normal timeouts remain and Windows puts the
# machine to sleep in the middle of the agent's work: CPU and GPU load does NOT
# count as activity, keyboard or mouse input does.
#
# Same protocol as the launcher: the previous values live in
# power-timeouts.json, and if this process dies the "Harness AI power restore"
# scheduled task puts them back.
#
#   harness-idle-sleep.ps1 -Off   disable idle sleep (saving the previous values)
#   harness-idle-sleep.ps1 -On    restore the previous values
#   harness-idle-sleep.ps1        show the current state
#
# Needs no administrator rights.
param(
  [switch]$Off,
  [switch]$On,
  # How long before the screen turns off when the user's setting is "never".
  # The stand itself does not care about a dark monitor.
  [int]$MonitorMinutes = 10,
  [string]$Saved = 'F:\Harness_AI\run\power-timeouts.json'
)

$RunDir = Split-Path -Parent $Saved
$LauncherLog = Join-Path $RunDir 'launcher.log'
function Log([string]$m) {
  try { Add-Content -Path $LauncherLog -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + " [idle-sleep] " + $m) } catch { }
}

# The 4th hex number in powercfg /q output is the AC value (min, max, step, AC,
# DC). The order does not depend on the system language, so parse by position.
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

  # Turning the screen off is fine: it blocks neither local nor phone work, and
  # there is no reason for it to burn all night. Only the "never" case is
  # touched - a deliberate user setting is left alone.
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
  # The launcher is alive: the state belongs to it, stay out of the way.
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
