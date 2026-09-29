# Shared helpers for the Windows-side install steps.

$script:StandRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

# Output language. Messages are written in English in the source; i18n/<lang>.json
# maps each English string to its translation, so another language is a data file
# rather than a second copy of every script. Placeholders here are .NET style
# ({0}, {1}); the bash side of the installer uses printf style (%s).
#   config.json -> "lang": "ru"   or   $env:HARNESS_LANG = 'ru'
# A string missing from the catalog is printed as it is, so a partial catalog
# degrades to English instead of breaking.
$script:Lang = if ($env:HARNESS_LANG) { $env:HARNESS_LANG } else {
  $cfgPath = Join-Path $script:StandRoot 'config.json'
  if (Test-Path $cfgPath) {
    try { (Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).lang } catch { $null }
  } else { $null }
}
if (-not $script:Lang) { $script:Lang = 'en' }

$script:I18n = @{}
if ($script:Lang -ne 'en') {
  $table = Join-Path $script:StandRoot "i18n\$($script:Lang).json"
  if (Test-Path $table) {
    try {
      (Get-Content $table -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $script:I18n[$_.Name] = [string]$_.Value }
    } catch { }
  }
}

function T {
  param([string]$Text, [object[]]$Values)
  $fmt = if ($script:I18n.ContainsKey($Text)) { $script:I18n[$Text] } else { $Text }
  if ($Values -and $Values.Count -gt 0) { [string]::Format($fmt, $Values) } else { $fmt }
}

function Write-Step { param([string]$Text, [Parameter(ValueFromRemainingArguments)][object[]]$Values) Write-Host ("==> " + (T $Text $Values)) -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text, [Parameter(ValueFromRemainingArguments)][object[]]$Values) Write-Host ("    v " + (T $Text $Values)) -ForegroundColor Green }
function Write-Info { param([string]$Text, [Parameter(ValueFromRemainingArguments)][object[]]$Values) Write-Host ("    . " + (T $Text $Values)) }
function Write-Warn { param([string]$Text, [Parameter(ValueFromRemainingArguments)][object[]]$Values) Write-Host ("    ! " + (T $Text $Values)) -ForegroundColor Yellow }
function Write-Err  { param([string]$Text, [Parameter(ValueFromRemainingArguments)][object[]]$Values) Write-Host ("    x " + (T $Text $Values)) -ForegroundColor Red }
function Write-Done { param([string]$Text, [Parameter(ValueFromRemainingArguments)][object[]]$Values) Write-Host ((T $Text $Values) + "`n") -ForegroundColor Green }

function Get-StandConfigPath {
  $custom = $env:HARNESS_CONFIG
  if ($custom) { return $custom }
  Join-Path $script:StandRoot 'config.json'
}

# Write config.json as UTF-8 WITHOUT a BOM.
#
# `Set-Content -Encoding UTF8` under Windows PowerShell 5.1 writes one, and the
# WSL side parses this file with JSON.parse, which a BOM breaks. Every cfg()
# read then fell back to its default in silence: the window came out 65536
# instead of the computed one, and windowsRoot reverted to the example's F:,
# so the install tried to mkdir under /mnt/f and got "Permission denied".
# Is this process elevated? Several steps need it, and the failures without it
# are unreadable: registering a scheduled task answers with a raw CIM error in
# the system language, which says nothing about administrator rights.
function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-ConfigJson {
  param([string]$Path, $Config)
  $json = ($Config | ConvertTo-Json -Depth 12)
  [System.IO.File]::WriteAllText($Path, $json + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Read-StandConfig {
  $path = Get-StandConfigPath
  if (-not (Test-Path $path)) {
    $example = Join-Path $script:StandRoot 'config.example.json'
    if (-not (Test-Path $example)) { throw (T 'neither config.json nor config.example.json in {0}' @($script:StandRoot)) }
    Copy-Item $example $path
    Write-Info 'config.json created from the example - adjust the paths and ports if you like'
  }
  # A hand-edited config.json is the first thing that breaks, and ConvertFrom-Json
  # answers with a parser message that means nothing to whoever edited it. The
  # two mistakes that actually happen: a single backslash in a Windows path
  # (JSON reads \H as an escape) and curly quotes pasted from a chat or a doc.
  $raw = Get-Content $path -Raw -Encoding UTF8
  try {
    $cfg = $raw | ConvertFrom-Json
  } catch {
    Write-Err 'config.json cannot be read: {0}' $path
    if ($raw -match '[\u201c\u201d\u00ab\u00bb]') {
      Write-Warn 'it contains curly quotes - JSON only accepts the straight " character.'
    }
    if ($raw -match '(?<!\\)\\(?![\\/"bfnrtu])') {
      Write-Warn 'a path has a single backslash. In JSON write it twice: "D:\\Harness_AI".'
      Write-Info 'a forward slash works just as well: "D:/Harness_AI".'
    }
    Write-Info 'the parser said: {0}' $_.Exception.Message
    Write-Info 'to start over, delete config.json - the next run copies config.example.json again.'
    throw (T 'config.json is not valid JSON')
  }

  # A forward slash is accepted in config.json - it is the one spelling a user
  # cannot get wrong by pasting a path - but everything downstream gets the
  # canonical Windows form. Shortcut targets in particular are handed to
  # IShellLink, which is not reliable about mixed separators.
  # In a -replace REPLACEMENT string a backslash is literal (only $ is special),
  # so '\\' here would insert two of them.
  if ($cfg.windowsRoot) { $cfg.windowsRoot = ($cfg.windowsRoot -replace '/', '\').TrimEnd('\') }

  # The configured drive may not exist: the example says F:, the machine may only
  # have C:. Fall back to the drive with the most free space and write the choice
  # back, so every step sees the same path.
  $drive = ($cfg.windowsRoot -replace '^([A-Za-z]):.*$', '$1')
  if ($drive -and -not (Test-Path "${drive}:\")) {
    $best = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
      Where-Object { $_.Free -ne $null -and $_.Name.Length -eq 1 } |
      Sort-Object Free -Descending | Select-Object -First 1
    if ($null -eq $best) { throw (T 'drive {0}: not found and no replacement could be chosen - set windowsRoot in config.json' @($drive)) }
    $tail = ($cfg.windowsRoot -replace '^[A-Za-z]:', '')
    $replacement = "$($best.Name):$tail"
    Write-Warn 'no drive {0}: - taking {1}: ({2} GB free)' $drive $best.Name ([math]::Round($best.Free/1GB))
    $cfg.windowsRoot = $replacement
    Write-ConfigJson $path $cfg
  }
  $cfg
}

# Set-StandConfig @{ 'server.ctx' = 65536; 'model.file' = 'x.gguf' }
# A dot in the key means nesting; values are written into config.json in place.
function Set-StandConfig {
  param([hashtable]$Values)
  $path = Get-StandConfigPath
  $cfg = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
  foreach ($key in $Values.Keys) {
    $parts = $key -split '\.'
    $node = $cfg
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
      $name = $parts[$i]
      if (-not $node.PSObject.Properties[$name]) {
        $node | Add-Member -NotePropertyName $name -NotePropertyValue ([pscustomobject]@{})
      }
      $node = $node.$name
    }
    $leaf = $parts[-1]
    if ($node.PSObject.Properties[$leaf]) { $node.$leaf = $Values[$key] }
    else { $node | Add-Member -NotePropertyName $leaf -NotePropertyValue $Values[$key] }
  }
  Write-ConfigJson $path $cfg
}

# Continue the install by itself after the reboot WSL2 needs.
#
# RunOnce and not Run: it fires at the next logon and deletes its own entry
# before running, so an abandoned install leaves nothing behind and a second
# reboot does not start it again. It runs UNELEVATED, hence Start-Process
# -Verb RunAs - the user answers one UAC prompt and the install carries on.
$script:ResumeKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$script:ResumeName = 'HarnessAiInstall'

function Set-ResumeAfterReboot {
  $cmd = Join-Path $script:StandRoot 'install.cmd'
  if (-not (Test-Path $cmd)) { return $false }
  # A RunOnce value is capped at 260 characters; a path deep enough to overflow
  # it is rare, but a silently truncated command would be worse than none.
  $value = "powershell -NoProfile -ExecutionPolicy Bypass -Command ""Start-Process -FilePath '$cmd' -Verb RunAs"""
  if ($value.Length -gt 255) { return $false }
  try {
    if (-not (Test-Path $script:ResumeKey)) { New-Item -Path $script:ResumeKey -Force | Out-Null }
    Set-ItemProperty -Path $script:ResumeKey -Name $script:ResumeName -Value $value
    return $true
  } catch { return $false }
}

function Clear-ResumeAfterReboot {
  try { Remove-ItemProperty -Path $script:ResumeKey -Name $script:ResumeName -ErrorAction SilentlyContinue } catch {}
}

# Run a native command whose stderr is redirected, without PowerShell turning
# that stderr into a terminating error.
#
# Under $ErrorActionPreference = 'Stop' - which every step sets, to fail fast -
# ANY redirection of a native command's error stream (2>$null as much as 2>&1)
# makes PowerShell wrap the first stderr line in a NativeCommandError and throw.
# curl draws its progress meter there; llama-server prints its version banner
# there; nvidia-smi warns there. Each of those was reported as a broken tool.
function Invoke-Native {
  param([scriptblock]$Command)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Command } finally { $ErrorActionPreference = $prev }
}

# Run a bash command inside WSL, passing its output through unchanged.
function Invoke-Wsl {
  param([string]$Distro, [string]$Command)
  & wsl.exe -d $Distro -- bash -lc $Command
  if ($LASTEXITCODE -ne 0) { throw (T 'the WSL step returned code {0}' @($LASTEXITCODE)) }
}

# Windows path -> WSL path: F:\Harness_AI -> /mnt/f/Harness_AI
function ConvertTo-WslPath {
  param([string]$Path)
  $p = $Path -replace '\\', '/'
  if ($p -match '^([A-Za-z]):(.*)$') { return "/mnt/$($Matches[1].ToLower())$($Matches[2])" }
  return $p
}
