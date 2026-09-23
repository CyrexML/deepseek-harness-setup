# Аварийное/независимое выключение системы Harness_AI.
#
# Нужен на случай, когда окно launcher'а закрыли крестиком или система была
# поднята вручную: launcher гасит всё сам, но полагаться на единственный путь
# выключения нельзя.
$ErrorActionPreference = 'Continue'
chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$Distro = 'Ubuntu'
$RunDir = 'F:\Harness_AI\run'

Write-Host '=== выключение Harness AI ===' -ForegroundColor Cyan

# Веб-интерфейс. Держатель `wsl.exe` мог пережить закрытие окна — снимаем и его.
& wsl.exe -d $Distro -- bash -lc '~/Harness_AI/scripts/stop-web.sh' 2>&1 | Out-Null
Get-CimInstance Win32_Process -Filter "Name = 'wsl.exe'" |
  Where-Object { $_.CommandLine -like '*harness-web-fg.sh*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Write-Host 'веб-интерфейс остановлен'

# Модель.
& "$RunDir\stop-server.ps1"

Write-Host ''
Write-Host 'Погасить также WSL? Закроет ВСЕ процессы Ubuntu — Claude Code, Docker,' -ForegroundColor Yellow
Write-Host 'открытые терминалы.' -ForegroundColor Yellow
$ans = Read-Host 'Гасить WSL? [y/N]'
if ($ans -match '^(y|Y|д|Д)') { & wsl.exe --shutdown; Write-Host 'WSL остановлен' }
else { Write-Host 'WSL оставлен работать' }

Write-Host ''
Write-Host 'Готово.' -ForegroundColor Green
Start-Sleep -Seconds 2
