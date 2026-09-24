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
function Write-Done { param([string]$Text, [Parameter(ValueFromRemainingArguments)][object[]]$Values) Write-Host ((T $Text $Values) + "`n") -ForegroundColor Green }

function Get-StandConfigPath {
  $custom = $env:HARNESS_CONFIG
  if ($custom) { return $custom }
  Join-Path $script:StandRoot 'config.json'
}

function Read-StandConfig {
  $path = Get-StandConfigPath
  if (-not (Test-Path $path)) {
    $example = Join-Path $script:StandRoot 'config.example.json'
    if (-not (Test-Path $example)) { throw (T 'neither config.json nor config.example.json in {0}' @($script:StandRoot)) }
    Copy-Item $example $path
    Write-Info 'config.json created from the example - adjust the paths and ports if you like'
  }
  $cfg = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json

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
    ($cfg | ConvertTo-Json -Depth 12) | Set-Content -Path $path -Encoding UTF8
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
  ($cfg | ConvertTo-Json -Depth 12) | Set-Content -Path $path -Encoding UTF8
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
