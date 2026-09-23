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
Write-Host (T '  Updating the Harness AI stand') -ForegroundColor Cyan
Write-Host ''

if (-not $NoPull) {
    Write-Step 'fetching a fresh installer'
    if (Test-Path (Join-Path $root '.git')) {
        Push-Location $root
        try {
            $before = (& git rev-parse --short HEAD)
            & git pull --ff-only
            $after = (& git rev-parse --short HEAD)
            if ($before -eq $after) { Write-Ok 'already the latest ({0})' $after } else { Write-Ok '{0} -> {1}' $before $after }
        } finally { Pop-Location }
    } else {
        Write-Info 'this folder is not a git clone - download a new ZIP from GitHub and unpack it over this one'
        Write-Info 'then run the update again'
    }
}

$lock = Join-Path $root 'stand.lock.json'
if (Test-Path $lock) {
    $l = Get-Content $lock -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Step 'what the new version pins'
    Write-Info 'harness: {0}' $l.harness.tag
    foreach ($name in $l.plugins.PSObject.Properties.Name) { Write-Info 'plugin: {0}@{1}' $name $l.plugins.$name }
    Write-Info 'patch layers: {0}' $l.patchLayers.Count
}

Write-Step 'backup before changing anything'
Invoke-Wsl $distro "bash -lc 'ts=`$(date +%Y%m%d-%H%M%S); dst=`$HOME/Harness_AI/run/backups/keep/before-update-`$ts; mkdir -p `$dst; cp `$HOME/.dsh/profiles/web/package.json `$HOME/.dsh/profiles/web/pnpm-lock.yaml `$HOME/.dsh/settings.yaml `$dst/ 2>/dev/null; echo `$dst'"

Write-Step 'copying the installer into WSL'
$wslHere = ConvertTo-WslPath $root
Invoke-Wsl $distro "rm -rf $wslRepo && mkdir -p $wslRepo && cp -r '$wslHere/.' $wslRepo/ && chmod +x $wslRepo/wsl/*.sh"
Write-Ok 'copied'

foreach ($s in @('10-harness.sh', '20-plugins.sh', '30-patches.sh', '40-config.sh')) {
    Write-Step 'WSL: {0}' $s
    Invoke-Wsl $distro "cd $wslRepo && bash wsl/$s"
}

Write-Step 'restarting the stand'
Invoke-Wsl $distro "bash -lc '`$HOME/Harness_AI/scripts/stop-web.sh >/dev/null 2>&1; nohup `$HOME/Harness_AI/scripts/start-web.sh >/dev/null 2>&1 & sleep 25; true'"
Write-Ok 'restarted'

Write-Step 'verifying'
Invoke-Wsl $distro "cd $wslRepo && bash wsl/50-verify.sh"

Write-Done 'update finished'
Write-Host (T '  If something broke: the profile backup is in ~/Harness_AI/run/backups/keep/before-update-*')
Write-Host '  Вернуть прежние версии: bash ~/Harness_AI/scripts/update-plugin.sh --rollback <папка бэкапа>'
Write-Host ''
