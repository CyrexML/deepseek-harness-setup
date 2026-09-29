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

Write-Step 'administrator rights'
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) { throw (T 'run PowerShell as administrator: installing WSL needs it') }
Write-Ok 'present'

Write-Step 'free disk space'
$drive = (Split-Path -Qualifier $cfg.windowsRoot).TrimEnd(':')
$free = [math]::Round((Get-PSDrive $drive).Free / 1GB)
if ($free -lt 40) { Write-Warn 'drive {0} has {1} GB free, at least 40 are needed' $drive $free }
else { Write-Ok 'drive {0} has {1} GB free' $drive $free }

Write-Step 'GPU and driver'
$smi = try { & nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>$null } catch { $null }
if ($smi) { Write-Ok $smi }
else {
  Write-Warn 'nvidia-smi not found. The stand is built for an NVIDIA GPU.'
  Write-Info 'Install a current GeForce/Studio driver from nvidia.com and run this step again.'
  Write-Info 'The stand still installs without a GPU, but the model then runs on the CPU - very slowly.'
}

Write-Step 'WSL2'
$wslOk = $false
try { & wsl.exe --status *>$null; $wslOk = ($LASTEXITCODE -eq 0) } catch { $wslOk = $false }
if (-not $wslOk) {
  Write-Info 'installing WSL2 (a reboot will be needed)'
  & wsl.exe --install --no-distribution
  Write-Warn 'reboot the computer and run install.cmd again'
  # Offering the reboot here saves the one step people get wrong: leaving the
  # console, finding the Start menu and hoping they remember to come back.
  # Never automatic - a reboot closes whatever else is open, so it takes a
  # deliberate keypress, and the countdown leaves room to change your mind.
  if ([Environment]::UserInteractive) {
    Write-Host ''
    $answer = Read-Host (T 'reboot now? type R and press Enter (anything else: later)')
    if ($answer -match '^\s*[RrКк]\s*$') {
      Write-Warn 'rebooting in 10 seconds - save your work now, Ctrl+C cancels'
      Start-Sleep -Seconds 10
      Write-Info 'after the reboot run install.cmd again - it continues from here'
      Restart-Computer -Force
      # Restart-Computer returns immediately; without this the script would fall
      # through to the exit while Windows is still closing sessions.
      Start-Sleep -Seconds 60
    }
  }
  # Exit code 2 = "not an error, but the install cannot go on in this boot".
  # install.cmd stops on it instead of running the remaining steps against a
  # machine that has no WSL yet.
  exit 2
}
Write-Ok 'installed'

Write-Step 'distribution {0}' $cfg.wslDistro
$installed = (& wsl.exe --list --quiet) -replace "`0", '' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($installed -contains $cfg.wslDistro) {
  Write-Ok 'already there'
} else {
  Write-Info 'installing {0} - a window will open to create the user' $cfg.wslDistro
  & wsl.exe --install -d $cfg.wslDistro
  Write-Info 'after creating the user close the distribution window and run install.cmd again'
  exit 2
}

Write-Step 'WSL version of the distribution'
$verbose = (& wsl.exe --list --verbose) -replace "`0", ''
if ($verbose -match "$($cfg.wslDistro)\s+\w+\s+1\b") {
  Write-Info 'the distribution is on WSL1 - converting to WSL2 (a few minutes)'
  & wsl.exe --set-version $cfg.wslDistro 2
}
Write-Ok 'WSL2'

Write-Step 'network access from WSL to Windows'
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
  Write-Ok 'firewall rule added (WSL only)'
} else {
  # A rule left by an older installer version may have no address restriction;
  # narrow it in place rather than leaving it open.
  $from = ($existing | Get-NetFirewallAddressFilter).RemoteAddress
  if ($from -contains 'Any') {
    Set-NetFirewallRule -DisplayName $rule -RemoteAddress $allowFrom | Out-Null
    Write-Ok 'firewall rule narrowed to the WSL subnet'
  } else { Write-Ok 'firewall rule already there (restricted)' }
}

Write-Done 'prerequisites are met'
