# Ставит ярлык «Harness AI» в меню Пуск.
# Запускать после каждой правки launcher'а: он же разворачивает его на F:.
#
# Ярлык ОДИН и работает переключателем — отдельного «стоп» больше нет.
# Старый ярлык выключения, если остался от прежней установки, удаляется.
$ErrorActionPreference = 'Stop'
chcp 65001 > $null
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$RunDir = 'F:\Harness_AI\run'
$Folder = Join-Path ([Environment]::GetFolderPath('Programs')) 'Harness AI'
New-Item -ItemType Directory -Force -Path $Folder | Out-Null

# Развёртывание launcher'ов из репозитория WSL — источник истины там.
& wsl.exe -d Ubuntu -- bash -lc `
  "cp ~/Harness_AI/scripts/harness-start.ps1 ~/Harness_AI/scripts/harness-stop.ps1 ~/Harness_AI/scripts/start-server.ps1 ~/Harness_AI/scripts/stop-server.ps1 ~/Harness_AI/scripts/harness-launch.vbs ~/Harness_AI/scripts/harness-splash.ps1 ~/Harness_AI/scripts/splash-whale.png ~/Harness_AI/scripts/harness.ico /mnt/f/Harness_AI/run/"

$shell = New-Object -ComObject WScript.Shell
$path  = Join-Path $Folder 'Harness AI.lnk'
$lnk = $shell.CreateShortcut($path)
# 2026-09-14: без консоли. wscript //B → harness-launch.vbs → powershell -Hidden;
# выключение — кнопки Power в вебе (Settings → Remote access) или второй клик.
$lnk.TargetPath = "$env:SystemRoot\System32\wscript.exe"
$lnk.Arguments  = "//B `"$RunDir\harness-launch.vbs`""
$lnk.WorkingDirectory = $RunDir
$lnk.Description = 'Запуск и выключение локального агента: модель + веб-интерфейс dsh'
# Значок — фирменный кит DeepSeek из favicon сборки dsh, пересобирается
# скриптом scripts/make-icon.sh. Путь обязан быть windows-овским: ярлык читает
# его сам, до всякого WSL.
$lnk.IconLocation = "$RunDir\harness.ico,0"
$lnk.Save()
Write-Host "поставлен: $path"

$old = Join-Path $Folder 'Harness AI — стоп.lnk'
if (Test-Path $old) { Remove-Item -Force $old; Write-Host "удалён прежний ярлык выключения: $old" }

Write-Host ''
Write-Host 'Готово. Ярлык в меню Пуск, папка «Harness AI».' -ForegroundColor Green
Write-Host 'Первый клик поднимает систему (без окна), второй — гасит; выключение с выбором WSL — в вебе: Settings → Remote access → Power.'
