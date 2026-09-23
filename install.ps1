# One-command install of the Harness AI stand.
#
#   right-click install.cmd -> Run as administrator
# or
#   powershell -ExecutionPolicy Bypass -File install.ps1
#
# Flags:
#   -SkipModel     leave the model alone (already downloaded and tuned)
#   -SkipLlama     skip the llama.cpp engine
#   -Step <name>   run one step only: prereqs, llama, wsl, model, tune, shortcuts, verify
#
# Every step is idempotent: an interrupted install can simply be started again.
[CmdletBinding()]
param(
  [switch]$SkipModel,
  [switch]$SkipLlama,
  [string]$Step = ''
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\windows\lib.ps1"

$cfg = Read-StandConfig
$distro = $cfg.wslDistro
$wslRepo = "`$HOME/harness-stand"

function Step-Prereqs   { & powershell -NoProfile -ExecutionPolicy Bypass -File "$here\windows\00-prereqs.ps1" }
function Step-Llama     { if (-not $SkipLlama) { & powershell -NoProfile -ExecutionPolicy Bypass -File "$here\windows\10-llama.ps1" } }
function Step-Model     { if (-not $SkipModel) { & powershell -NoProfile -ExecutionPolicy Bypass -File "$here\windows\20-model.ps1" } }
function Step-Tune      { if (-not $SkipModel) { & powershell -NoProfile -ExecutionPolicy Bypass -File "$here\windows\30-tune.ps1" } }
function Step-Shortcuts { & powershell -NoProfile -ExecutionPolicy Bypass -File "$here\windows\40-shortcuts.ps1" }

# The installer tree is copied into WSL: the Linux steps run from there, and the
# maintenance scripts stay there afterwards.
function Copy-ToWsl {
  Write-Step 'copying the installer into WSL'
  $wslHere = ConvertTo-WslPath $here
  Invoke-Wsl $distro "rm -rf $wslRepo && mkdir -p $wslRepo && cp -r '$wslHere/.' $wslRepo/ && chmod +x $wslRepo/wsl/*.sh"
  Write-Ok 'copied'
}

function Step-Wsl {
  Copy-ToWsl
  foreach ($s in @('00-toolchain.sh', '10-harness.sh', '20-plugins.sh', '30-patches.sh', '40-config.sh')) {
    Write-Step 'WSL: {0}' $s
    Invoke-Wsl $distro "cd $wslRepo && bash wsl/$s"
  }
}

function Step-Verify {
  Write-Step 'verifying'
  Invoke-Wsl $distro "cd $wslRepo && bash wsl/50-verify.sh"
}

if ($Step) {
  switch ($Step) {
    'prereqs'   { Step-Prereqs }
    'llama'     { Step-Llama }
    'wsl'       { Step-Wsl }
    'model'     { Step-Model }
    'tune'      { Step-Tune }
    'shortcuts' { Step-Shortcuts }
    'verify'    { Step-Verify }
    default     { throw (T 'unknown step: {0}' @($Step)) }
  }
  return
}

Write-Host ''
Write-Host (T '  Harness AI - installing the stand') -ForegroundColor Cyan
Write-Host (T '  a local model plus an agent interface you can reach from a phone')
Write-Host ''

Step-Prereqs
Step-Llama
Step-Model
Step-Wsl
Step-Tune
Step-Shortcuts
Step-Verify

Write-Host ''
Write-Done 'done'
Write-Host (T '  To start: the Harness AI shortcut on the desktop.')
Write-Host (T '  Interface: http://127.0.0.1:{0}' @($cfg.webPort))
Write-Host (T '  To remove: powershell -ExecutionPolicy Bypass -File uninstall.ps1')
Write-Host ''
