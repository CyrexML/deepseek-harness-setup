# One-command install of the Harness AI stand.
#
#   right-click install.cmd -> Run as administrator
# or
#   powershell -ExecutionPolicy Bypass -File windows\install.ps1
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
# This script lives in windows\, so the repository root - which is what every
# path below is relative to, including the tree copied into WSL - is one up.
$here = Split-Path -Parent $PSScriptRoot
. "$here\windows\lib.ps1"

$cfg = Read-StandConfig
$distro = $cfg.wslDistro
$wslRepo = "`$HOME/harness-stand"

# Each Windows step runs in its own PowerShell, so a `throw` inside it reaches
# this script only as an exit code - nothing here sees the exception. Without
# this check the install marched on over a failed step and the first real error
# was buried under four screens of later output. Code 2 is the one non-error
# stop: the machine needs a reboot (or a WSL user) before the run can continue.
function Invoke-WinStep {
  param([string]$Name, [string]$Script)
  & powershell -NoProfile -ExecutionPolicy Bypass -File "$here\windows\$Script"
  $code = $LASTEXITCODE
  if ($code -eq 2) {
    Write-Host ''
    Write-Warn 'the install stops here: finish what the step above asks, then run install.cmd again'
    exit 2
  }
  if ($code -ne 0) {
    Write-Host ''
    Write-Err 'step "{0}" failed (code {1}) - the message above says why' $Name $code
    Write-Info 'nothing later was run. Fix that one thing and start install.cmd again:'
    Write-Info 'the install is idempotent, finished steps are skipped.'
    Write-Info 'to retry this step alone:  install.cmd -Step {0}' $Name
    exit $code
  }
}

function Step-Prereqs   { Invoke-WinStep 'prereqs'   '00-prereqs.ps1' }
function Step-Llama     { if (-not $SkipLlama) { Invoke-WinStep 'llama' '10-llama.ps1' } }
function Step-Model     { if (-not $SkipModel) { Invoke-WinStep 'model' '20-model.ps1' } }
function Step-Tune      { if (-not $SkipModel) { Invoke-WinStep 'tune'  '30-tune.ps1' } }
function Step-Shortcuts { Invoke-WinStep 'shortcuts' '40-shortcuts.ps1' }

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

# The tuning step leaves llama-server running so the verify above has something
# to talk to - but this whole install is elevated, and the Start-menu shortcut is
# not. An elevated server the shortcut cannot stop is exactly what greeted the
# first person who clicked it. So the install hands the machine over clean.
Write-Step 'handing over'
$stopServer = Join-Path $cfg.windowsRoot 'run\stop-server.ps1'
if (Test-Path $stopServer) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $stopServer | Out-Null
  Write-Ok 'the model server was stopped - the shortcut starts its own'
}

# The install finished, so a pending "continue at next logon" entry has nothing
# left to do. RunOnce would have dropped it on firing anyway; this covers the
# run that reached the end without a reboot in between.
Clear-ResumeAfterReboot

Write-Host ''
Write-Done 'done'
Write-Host (T '  To start: the Harness AI shortcut in the Start menu (search for "Harness").')
Write-Host (T '  Interface: http://127.0.0.1:{0}' @($cfg.webPort))
Write-Host (T '  To remove: run uninstall.cmd')
Write-Host ''
