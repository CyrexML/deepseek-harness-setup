# Complete removal of the Harness AI stand.
#
#   right-click uninstall.cmd -> Run as administrator
#
# Flags:
#   -KeepModel     keep the downloaded models (13+ GB, slow to fetch again)
#   -KeepData      keep chats, agent memory and settings (~/.dsh)
#   -KeepWsl       do not remove the WSL distribution (the default anyway)
#   -RemoveWsl     remove the WSL distribution ENTIRELY, with everything in it
#   -Yes           do not ask for confirmation
#
# Removed by default: shortcuts and the scheduled task, the firewall rule, the
# llama.cpp engine, the stand's directories inside WSL (~/Harness_AI,
# ~/tools/deepseek-harness, ~/harness-stand) and DSH data (~/.dsh). Models too,
# unless -KeepModel. Windows, WSL, drivers and Node.js are left alone: other
# software may depend on them.
[CmdletBinding()]
param(
  [switch]$KeepModel,
  [switch]$KeepData,
  [switch]$KeepWsl,
  [switch]$RemoveWsl,
  # Wipe everything, including the WSL distribution. A separate flag because the
  # distribution may hold unrelated data.
  [switch]$All,
  [switch]$Yes
)
if ($All) { $RemoveWsl = $true; $KeepModel = $false; $KeepData = $false }
$ErrorActionPreference = 'Continue'
# This script lives in windows\, so the repository root - which is what every
# path below is relative to, including the tree copied into WSL - is one up.
$here = Split-Path -Parent $PSScriptRoot
. "$here\windows\lib.ps1"

$cfg = Read-StandConfig
$root = $cfg.windowsRoot
$distro = $cfg.wslDistro

# Asked once, up front. Without it every WSL step prints the host's own
# "no such distribution" error and then reports "done", which reads like the
# removal half worked when in fact there was nothing left to remove.
$distroPresent = $false
try {
  $installed = @((& wsl.exe --list --quiet) -replace "`0", '' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $distroPresent = $installed -contains $distro
} catch { $distroPresent = $false }

# An install abandoned between the reboot and the second pass can leave a
# "continue at next logon" entry behind; removing the stand must not leave it
# to fire later.
Clear-ResumeAfterReboot

Write-Host ''
Write-Host (T '  Removing the Harness AI stand') -ForegroundColor Yellow
Write-Host ''
# The flags are for scripts. Someone who started uninstall.cmd from Explorer has
# nowhere to type one, so the same choice is offered here - and it has to come
# before the list, because the choice decides what the list says.
$flagsGiven = $KeepModel -or $KeepData -or $KeepWsl -or $RemoveWsl -or $All
if (-not $Yes -and -not $flagsGiven -and [Environment]::UserInteractive) {
  Write-Host (T '  How much to remove:') -ForegroundColor Cyan
  Write-Host (T '    1   the stand; the WSL distribution itself stays')
  Write-Host (T '    2   the same, but keep the downloaded models')
  Write-Host (T '    3   the same, but keep chats, agent memory and settings')
  Write-Host (T '    4   everything, including the whole WSL distribution')
  Write-Host (T '        2 and 3 can be combined: type 23')
  Write-Host ''
  $mode = Read-Host (T '  your choice [1]')
  if ($mode -match '4') {
    $RemoveWsl = $true; $KeepModel = $false; $KeepData = $false
  } else {
    if ($mode -match '2') { $KeepModel = $true }
    if ($mode -match '3') { $KeepData = $true }
  }
  Write-Host ''
}

Write-Host (T '  to be removed:')
Write-Host (T '    - shortcuts, the scheduled task, the firewall rule (port {0})' @($cfg.modelPort))
Write-Host (T '    - engine and launch scripts: {0}\llama.cpp, {0}\run' @($root))
if (-not $KeepModel) { Write-Host (T '    - models: {0}\models' @($root)) } else { Write-Host (T '    - models: KEPT (-KeepModel)') }
if (-not $KeepData)  { Write-Host (T '    - DSH data inside WSL: ~/.dsh (chats, agent memory, settings)') }
else { Write-Host (T '    - DSH data: KEPT (-KeepData)') }
Write-Host (T '    - stand code inside WSL: ~/Harness_AI, ~/tools/deepseek-harness, ~/harness-stand')
if ($RemoveWsl -and $distroPresent) { Write-Host (T '    - THE ENTIRE WSL DISTRIBUTION "{0}"' @($distro)) -ForegroundColor Red }
Write-Host ''
Write-Host (T '  Left alone: Windows itself, WSL as a system component, the GPU driver and your projects outside the stand.')
Write-Host ''
Write-Host (T '  The same choices exist as flags, for scripts: -KeepModel, -KeepData, -All, -Yes.')
Write-Host ''

if (-not $Yes) {
  $word = T 'delete'
  $answer = Read-Host (T '  Remove it? Type "{0}" to confirm' @($word))
  if ($answer -ne $word) { Write-Host (T '  cancelled'); return }
}

function Try-Do([string]$what, [scriptblock]$action) {
  Write-Step $what
  try { & $action; Write-Ok 'done' } catch { Write-Warn 'failed: {0}' $_.Exception.Message }
}

Try-Do 'stopping the stand' {
  $stop = Join-Path $root 'run\harness-stop.ps1'
  if (Test-Path $stop) { & powershell -NoProfile -ExecutionPolicy Bypass -File $stop | Out-Null }
  $stopServer = Join-Path $root 'run\stop-server.ps1'
  if (Test-Path $stopServer) { & powershell -NoProfile -ExecutionPolicy Bypass -File $stopServer | Out-Null }
  Get-Process llama-server -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  if ($distroPresent) {
    & wsl.exe -d $distro -- bash -lc 'pkill -f "bin.js web" 2>/dev/null; pkill -f cloudflared 2>/dev/null; true' 2>$null
  }
}

Try-Do 'restoring the sleep timeouts' {
  $idle = Join-Path $root 'run\harness-idle-sleep.ps1'
  if (Test-Path $idle) { & powershell -NoProfile -ExecutionPolicy Bypass -File $idle -On | Out-Null }
  else { & powercfg.exe /change standby-timeout-ac 15 | Out-Null }
}

Try-Do 'removing the scheduled task' {
  Get-ScheduledTask -TaskName 'Harness AI power restore' -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
}

Try-Do 'removing the shortcuts' {
  foreach ($dir in @([Environment]::GetFolderPath('Desktop'),
                     (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))) {
    Get-ChildItem -Path $dir -Filter 'Harness AI*.lnk' -ErrorAction SilentlyContinue | Remove-Item -Force
  }
}

Try-Do 'removing the firewall rule' {
  Get-NetFirewallRule -DisplayName "Harness AI*" -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

if ($distroPresent) {
  Try-Do 'removing the stand contents inside WSL' {
    $keep = if ($KeepData) { 'true' } else { 'rm -rf "$HOME/.dsh"' }
    & wsl.exe -d $distro -- bash -lc "rm -rf `"`$HOME/Harness_AI`" `"`$HOME/tools/deepseek-harness`" `"`$HOME/harness-stand`"; $keep" 2>$null
  }
} else {
  Write-Step 'the stand inside WSL'
  Write-Ok 'the distribution "{0}" is not installed - nothing to remove there' $distro
}

Try-Do 'removing the engine and the launch scripts' {
  foreach ($sub in @('llama.cpp', 'run', 'exchange')) {
    $path = Join-Path $root $sub
    if (Test-Path $path) { Remove-Item -Recurse -Force $path -ErrorAction SilentlyContinue }
  }
}

if (-not $KeepModel) {
  Try-Do 'removing the models' {
    $models = Join-Path $root 'models'
    if (Test-Path $models) { Remove-Item -Recurse -Force $models -ErrorAction SilentlyContinue }
  }
}

Try-Do 'removing the empty stand directory' {
  if ((Test-Path $root) -and -not (Get-ChildItem $root -Force -ErrorAction SilentlyContinue)) {
    Remove-Item -Force $root -ErrorAction SilentlyContinue
  }
}

if ($RemoveWsl -and -not $KeepWsl -and -not $distroPresent) {
  Write-Step 'the WSL distribution'
  Write-Ok '"{0}" is already gone' $distro
} elseif ($RemoveWsl -and -not $KeepWsl) {
  # No third prompt here. Reaching this line already took choosing the mode that
  # names the distribution in red, then typing the confirmation word - asking
  # for the distribution's name on top of that only taught people to guess.
  Write-Warn 'removing the whole WSL distribution "{0}" - this wipes EVERYTHING that was in it' $distro
  & wsl.exe --unregister $distro
}

Write-Host ''
Write-Done 'the stand is removed'
Write-Host (T '  Left untouched: Windows, WSL, the NVIDIA driver, Node.js inside the distribution.')
if ($KeepModel) { Write-Host (T '  The models stayed in {0}\models - a new install will pick them up.' @($root)) }
if ($KeepData)  { Write-Host (T '  DSH data stayed in ~/.dsh inside WSL.') }
Write-Host ''
