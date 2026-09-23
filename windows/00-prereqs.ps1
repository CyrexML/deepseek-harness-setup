# Шаг 0: то, без чего дальше ничего не поедет — WSL2, дистрибутив, драйвер NVIDIA.
#
#   powershell -ExecutionPolicy Bypass -File windows\00-prereqs.ps1
#
# Может потребовать перезагрузку: включение WSL2 на чистой Windows — это
# установка компонентов системы. Скрипт скажет об этом прямо и его можно
# запустить повторно после перезагрузки — он продолжит с того же места.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\lib.ps1"

$cfg = Read-StandConfig

Write-Step 'права администратора'
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw 'запустите PowerShell от имени администратора: установка WSL требует прав' }
Write-Ok 'есть'

Write-Step 'место на диске'
$drive = (Split-Path -Qualifier $cfg.windowsRoot).TrimEnd(':')
$free = [math]::Round((Get-PSDrive $drive).Free / 1GB)
if ($free -lt 40) { Write-Warn "на диске $drive свободно $free ГБ, нужно хотя бы 40" }
else { Write-Ok "на диске $drive свободно $free ГБ" }

Write-Step 'видеокарта и драйвер'
$smi = try { & nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>$null } catch { $null }
if ($smi) { Write-Ok $smi }
else {
  Write-Warn 'nvidia-smi не найден. Стенд рассчитан на видеокарту NVIDIA.'
  Write-Info 'Поставьте свежий драйвер GeForce/Studio с nvidia.com и запустите этот шаг снова.'
  Write-Info 'Без видеокарты стенд тоже поднимется, но модель будет считаться на процессоре — очень медленно.'
}

Write-Step 'WSL2'
$wslOk = $false
try { & wsl.exe --status *>$null; $wslOk = ($LASTEXITCODE -eq 0) } catch { $wslOk = $false }
if (-not $wslOk) {
  Write-Info 'ставлю WSL2 (потребуется перезагрузка)'
  & wsl.exe --install --no-distribution
  Write-Warn 'перезагрузите компьютер и запустите этот скрипт снова'
  return
}
Write-Ok 'установлен'

Write-Step "дистрибутив $($cfg.wslDistro)"
$installed = (& wsl.exe --list --quiet) -replace "`0", '' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($installed -contains $cfg.wslDistro) {
  Write-Ok 'уже есть'
} else {
  Write-Info "устанавливаю $($cfg.wslDistro) — откроется окно с созданием пользователя"
  & wsl.exe --install -d $cfg.wslDistro
  Write-Info 'после создания пользователя закройте окно дистрибутива и запустите install.ps1 снова'
  return
}

Write-Step 'версия WSL у дистрибутива'
$verbose = (& wsl.exe --list --verbose) -replace "`0", ''
if ($verbose -match "$($cfg.wslDistro)\s+\w+\s+1\b") {
  Write-Info 'дистрибутив на WSL1 — перевожу на WSL2 (это займёт несколько минут)'
  & wsl.exe --set-version $cfg.wslDistro 2
}
Write-Ok 'WSL2'

Write-Step 'доступ WSL → Windows по сети'
# llama-server слушает на Windows, интерфейс живёт в WSL. Правило брандмауэра
# нужно, иначе запросы из WSL в порт модели молча теряются.
# ВАЖНО: правило ограничено подсетью WSL (172.16.0.0/12) и петлёй. Открывать
# порт всем ("любой адрес") нельзя: llama-server работает без ключа доступа, и
# в общей сети — гостевой Wi-Fi, общежитие, офис — к модели и видеокарте смог
# бы обратиться кто угодно с этой сети.
$rule = "Harness AI: llama-server $($cfg.modelPort)"
$allowFrom = @('172.16.0.0/12', '127.0.0.1')
$existing = Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue
if (-not $existing) {
  New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow `
      -Protocol TCP -LocalPort $cfg.modelPort -RemoteAddress $allowFrom -Profile Any | Out-Null
  Write-Ok "правило брандмауэра добавлено (только из WSL)"
} else {
  # Правило могло остаться от прежней версии установщика — без ограничения по
  # адресу. Молча оставлять его нельзя, поэтому сужаем на месте.
  $from = ($existing | Get-NetFirewallAddressFilter).RemoteAddress
  if ($from -contains 'Any') {
    Set-NetFirewallRule -DisplayName $rule -RemoteAddress $allowFrom | Out-Null
    Write-Ok 'правило брандмауэра сужено до подсети WSL'
  } else { Write-Ok 'правило брандмауэра уже есть (ограничено)' }
}

Write-Done 'предварительные условия выполнены'
