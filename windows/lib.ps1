# Общие мелочи для шагов установки на стороне Windows.

$script:StandRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Write-Step { param([string]$Text) Write-Host "==> $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "    v $Text" -ForegroundColor Green }
function Write-Info { param([string]$Text) Write-Host "    . $Text" }
function Write-Warn { param([string]$Text) Write-Host "    ! $Text" -ForegroundColor Yellow }
function Write-Done { param([string]$Text) Write-Host "v $Text`n" -ForegroundColor Green }

function Get-StandConfigPath {
  $custom = $env:HARNESS_CONFIG
  if ($custom) { return $custom }
  Join-Path $script:StandRoot 'config.json'
}

function Read-StandConfig {
  $path = Get-StandConfigPath
  if (-not (Test-Path $path)) {
    $example = Join-Path $script:StandRoot 'config.example.json'
    if (-not (Test-Path $example)) { throw "нет ни config.json, ни config.example.json в $script:StandRoot" }
    Copy-Item $example $path
    Write-Info "создан config.json из примера — при желании поправьте пути и порты"
  }
  $cfg = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json

  # Диск из настроек может не существовать: в примере стоит F:, а у человека
  # только C:. Тогда выбираем сами — диск с наибольшим свободным местом (не
  # меньше 40 ГБ) — и записываем выбор обратно, чтобы все шаги видели одно и то же.
  $drive = ($cfg.windowsRoot -replace '^([A-Za-z]):.*$', '$1')
  if ($drive -and -not (Test-Path "${drive}:\")) {
    $best = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
      Where-Object { $_.Free -ne $null -and $_.Name.Length -eq 1 } |
      Sort-Object Free -Descending | Select-Object -First 1
    if ($null -eq $best) { throw "диск $drive`: не найден, и подобрать замену не удалось — укажите windowsRoot в config.json" }
    $tail = ($cfg.windowsRoot -replace '^[A-Za-z]:', '')
    $replacement = "$($best.Name):$tail"
    Write-Warn "диска $drive`: нет — беру $($best.Name): ($([math]::Round($best.Free/1GB)) ГБ свободно)"
    $cfg.windowsRoot = $replacement
    ($cfg | ConvertTo-Json -Depth 12) | Set-Content -Path $path -Encoding UTF8
  }
  $cfg
}

# Set-StandConfig @{ 'server.ctx' = 65536; 'model.file' = 'x.gguf' }
# Точка в ключе — вложенность. Значения пишутся в config.json на месте.
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

# Выполнить bash-скрипт внутри WSL, показывая вывод как есть.
function Invoke-Wsl {
  param([string]$Distro, [string]$Command)
  & wsl.exe -d $Distro -- bash -lc $Command
  if ($LASTEXITCODE -ne 0) { throw "шаг в WSL вернул код $LASTEXITCODE" }
}

# Путь Windows → путь внутри WSL: F:\Harness_AI → /mnt/f/Harness_AI
function ConvertTo-WslPath {
  param([string]$Path)
  $p = $Path -replace '\\', '/'
  if ($p -match '^([A-Za-z]):(.*)$') { return "/mnt/$($Matches[1].ToLower())$($Matches[2])" }
  return $p
}
