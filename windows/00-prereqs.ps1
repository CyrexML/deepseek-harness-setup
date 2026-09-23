# Step 0: what nothing else works without - WSL2, a distribution, the NVIDIA driver.
#
#   powershell -ExecutionPolicy Bypass -File windows\00-prereqs.ps1
#
# May require a reboot: enabling WSL2 on a clean Windows installs system
# components. The script says so and can be run again afterwards - it continues
# from the same place.
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
# llama-server listens on Windows, the interface runs in WSL; without this rule
# requests from WSL to the model port are silently dropped.
# Scoped to the WSL subnet and loopback on purpose: llama-server runs without an
# API key, so an "any address" rule would hand the model and the GPU to everyone
# on the same network.
$rule = "Harness AI: llama-server $($cfg.modelPort)"
$allowFrom = @('172.16.0.0/12', '127.0.0.1')
$existing = Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue
if (-not $existing) {
  New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow `
      -Protocol TCP -LocalPort $cfg.modelPort -RemoteAddress $allowFrom -Profile Any | Out-Null
  Write-Ok "правило брандмауэра добавлено (только из WSL)"
} else {
  # A rule left by an older installer version may have no address restriction;
  # narrow it in place rather than leaving it open.
  $from = ($existing | Get-NetFirewallAddressFilter).RemoteAddress
  if ($from -contains 'Any') {
    Set-NetFirewallRule -DisplayName $rule -RemoteAddress $allowFrom | Out-Null
    Write-Ok 'правило брандмауэра сужено до подсети WSL'
  } else { Write-Ok 'правило брандмауэра уже есть (ограничено)' }
}

Write-Done 'предварительные условия выполнены'
