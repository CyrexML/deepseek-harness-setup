# Update the stand to the state recorded in the repository.
#
#   double-click update.cmd
# or
#   powershell -ExecutionPolicy Bypass -File windows\50-update.ps1
#   ... -NoPull   do not pull from GitHub, apply what is already here
#
# Pulls a fresh installer (git pull, when the folder is a clone), backs up the
# profile, applies stand.lock.json - harness and plugin versions, patch layers,
# settings - restarts the stand and verifies it. The backup is taken BEFORE any
# change, and the rollback command is printed if verification fails.
[CmdletBinding()]
param([switch]$NoPull)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\lib.ps1"

$cfg = Read-StandConfig
$distro = $cfg.wslDistro
$root = Split-Path -Parent $here
$wslRepo = "`$HOME/harness-stand"

Write-Host ''
Write-Host '  Обновление стенда Harness AI' -ForegroundColor Cyan
Write-Host ''

if (-not $NoPull) {
    Write-Step 'свежая версия установщика'
    if (Test-Path (Join-Path $root '.git')) {
        Push-Location $root
        try {
            $before = (& git rev-parse --short HEAD)
            & git pull --ff-only
            $after = (& git rev-parse --short HEAD)
            if ($before -eq $after) { Write-Ok "уже последняя ($after)" } else { Write-Ok "$before → $after" }
        } finally { Pop-Location }
    } else {
        Write-Info 'папка не является клоном git — скачайте новый ZIP с GitHub и распакуйте поверх'
        Write-Info 'после этого запустите обновление снова'
    }
}

$lock = Join-Path $root 'stand.lock.json'
if (Test-Path $lock) {
    $l = Get-Content $lock -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Step 'что зафиксировано в новой версии'
    Write-Info "харнес: $($l.harness.tag)"
    foreach ($name in $l.plugins.PSObject.Properties.Name) { Write-Info "плагин: $name@$($l.plugins.$name)" }
    Write-Info "патч-слоёв: $($l.patchLayers.Count)"
}

Write-Step 'бэкап перед изменениями'
Invoke-Wsl $distro "bash -lc 'ts=`$(date +%Y%m%d-%H%M%S); dst=`$HOME/Harness_AI/run/backups/keep/before-update-`$ts; mkdir -p `$dst; cp `$HOME/.dsh/profiles/web/package.json `$HOME/.dsh/profiles/web/pnpm-lock.yaml `$HOME/.dsh/settings.yaml `$dst/ 2>/dev/null; echo `$dst'"

Write-Step 'копирую установщик внутрь WSL'
$wslHere = ConvertTo-WslPath $root
Invoke-Wsl $distro "rm -rf $wslRepo && mkdir -p $wslRepo && cp -r '$wslHere/.' $wslRepo/ && chmod +x $wslRepo/wsl/*.sh"
Write-Ok 'скопирован'

foreach ($s in @('10-harness.sh', '20-plugins.sh', '30-patches.sh', '40-config.sh')) {
    Write-Step "WSL: $s"
    Invoke-Wsl $distro "cd $wslRepo && bash wsl/$s"
}

Write-Step 'перезапуск стенда'
Invoke-Wsl $distro "bash -lc '`$HOME/Harness_AI/scripts/stop-web.sh >/dev/null 2>&1; nohup `$HOME/Harness_AI/scripts/start-web.sh >/dev/null 2>&1 & sleep 25; true'"
Write-Ok 'перезапущен'

Write-Step 'проверка'
Invoke-Wsl $distro "cd $wslRepo && bash wsl/50-verify.sh"

Write-Done 'обновление закончено'
Write-Host '  Если что-то сломалось: бэкап профиля лежит в ~/Harness_AI/run/backups/keep/before-update-*'
Write-Host '  Вернуть прежние версии: bash ~/Harness_AI/scripts/update-plugin.sh --rollback <папка бэкапа>'
Write-Host ''
