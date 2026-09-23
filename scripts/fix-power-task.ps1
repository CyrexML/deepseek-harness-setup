# Re-register the "Harness AI power restore" task without a flashing console.
#
#   RIGHT-CLICK PowerShell -> Run as administrator, then:
#   powershell -ExecutionPolicy Bypass -File F:\Harness_AI\run\fix-power-task.ps1
#
# The task used to run powershell.exe directly, which flashed a console window
# every 15 minutes: conhost creates it BEFORE PowerShell applies -WindowStyle
# Hidden. Through wscript.exe + harness-hidden.vbs there is no window at all.
$ErrorActionPreference = 'Stop'
$runDir = 'F:\Harness_AI\run'
$hidden = Join-Path $runDir 'harness-hidden.vbs'
$restore = Join-Path $runDir 'harness-restore-power.ps1'
foreach ($f in @($hidden, $restore)) { if (-not (Test-Path $f)) { throw "missing file: $f" } }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'run this as administrator' }

$action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\wscript.exe" -Argument "`"$hidden`" `"$restore`""
$logon = New-ScheduledTaskTrigger -AtLogOn
$logon.Delay = 'PT30S'
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName 'Harness AI power restore' -Action $action `
  -Trigger @($logon, $repeat) -Settings $settings -Force | Out-Null

$t = Get-ScheduledTask -TaskName 'Harness AI power restore'
foreach ($a in $t.Actions) { Write-Host ("action: " + $a.Execute + " " + $a.Arguments) }
Write-Host 'done: the console window should not appear any more'
