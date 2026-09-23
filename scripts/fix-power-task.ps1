# Перерегистрация задачи «Harness AI power restore» без мигающего окна консоли.
#
#   ПРАВЫЙ КЛИК по PowerShell → «Запуск от имени администратора», затем:
#   powershell -ExecutionPolicy Bypass -File F:\Harness_AI\run\fix-power-task.ps1
#
# Зачем: задача запускалась действием powershell.exe, и раз в 15 минут на экране
# мигало окно консоли — его создаёт conhost ДО того, как PowerShell применит
# -WindowStyle Hidden. Через wscript.exe + harness-hidden.vbs окна нет вовсе.
$ErrorActionPreference = 'Stop'
$runDir = 'F:\Harness_AI\run'
$hidden = Join-Path $runDir 'harness-hidden.vbs'
$restore = Join-Path $runDir 'harness-restore-power.ps1'
foreach ($f in @($hidden, $restore)) { if (-not (Test-Path $f)) { throw "нет файла $f" } }

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'нужен запуск от имени администратора' }

$action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\wscript.exe" -Argument "`"$hidden`" `"$restore`""
$logon = New-ScheduledTaskTrigger -AtLogOn
$logon.Delay = 'PT30S'
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes 15) -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName 'Harness AI power restore' -Action $action `
  -Trigger @($logon, $repeat) -Settings $settings -Force | Out-Null

$t = Get-ScheduledTask -TaskName 'Harness AI power restore'
foreach ($a in $t.Actions) { Write-Host ("действие: " + $a.Execute + " " + $a.Arguments) }
Write-Host 'готово: окно консоли больше появляться не должно'
