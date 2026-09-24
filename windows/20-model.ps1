# Model wizard: pick one for the GPU, download it, verify it.
#
# Run:     powershell -ExecutionPolicy Bypass -File windows\20-model.ps1
# Flags:   -ListOnly   print the table and exit
#          -Model <file name>  take a specific file, no matching
#          -NoDownload write the choice into config.json only (place the file yourself)
[CmdletBinding()]
param(
  [switch]$ListOnly,
  [string]$Model = "",
  [switch]$NoDownload
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\lib.ps1"

$cfg = Read-StandConfig
$modelsDir = Join-Path $cfg.windowsRoot 'models'

# Catalog of verified options, family first, then quants from large to small.
# vramGb is how much VRAM the model needs in total (weights + context cache +
# buffers); sizeGb is the file size. The wizard takes the largest quant that
# fits; if none does, it offers a smaller quant of the same file rather than a
# different model.
#
# mtp marks models that can predict several tokens ahead (--spec-type
# draft-mtp): +50-100% generation speed, which is why they come first.
$catalog = @(
  @{ name='Qwen3.5-9B-MTP-UD-Q4_K_XL.gguf';  repo='unsloth/Qwen3.5-9B-MTP-GGUF';  vramGb=10; sizeGb=6.1;  ctx=32768; mtp=$true;  family='Qwen3.5 9B'; note='smallest option: 10 GB of VRAM' }
  @{ name='Qwen3.5-9B-MTP-UD-Q5_K_XL.gguf';  repo='unsloth/Qwen3.5-9B-MTP-GGUF';  vramGb=12; sizeGb=6.9;  ctx=49152; mtp=$true;  family='Qwen3.5 9B'; note='minimum recommended configuration' }
  @{ name='Qwen3.5-9B-MTP-UD-Q6_K_XL.gguf';  repo='unsloth/Qwen3.5-9B-MTP-GGUF';  vramGb=14; sizeGb=9.0;  ctx=65536; mtp=$true;  family='Qwen3.5 9B'; note='same family, higher precision' }
  @{ name='Qwen3.8-27B-UD-Q3_K_XL.gguf';     repo='unsloth/Qwen3.8-27B-GGUF';     vramGb=16; sizeGb=13;   ctx=65536; mtp=$true;  family='Qwen3.8 27B'; note="the author's configuration (RTX 5080, 16 GB)" }
  @{ name='Qwen3.8-27B-UD-Q4_K_XL.gguf';     repo='unsloth/Qwen3.8-27B-GGUF';     vramGb=24; sizeGb=17;   ctx=65536; mtp=$true;  family='Qwen3.8 27B'; note='same model, more precise' }
  @{ name='Qwen3.8-27B-Q5_K_M.gguf';         repo='unsloth/Qwen3.8-27B-GGUF';     vramGb=32; sizeGb=21;   ctx=131072; mtp=$true; family='Qwen3.8 27B'; note='for cards of 32 GB and up' }
)

function Get-VramGb {
  try {
    $line = (& nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>$null | Select-Object -First 1)
    if (-not $line) { return $null }
    $parts = $line -split ','
    $mb = [int](($parts[1] -replace '[^0-9]', ''))
    return @{ name = $parts[0].Trim(); gb = [math]::Round($mb / 1024, 0) }
  } catch { return $null }
}

Write-Step 'GPU'
$gpu = Get-VramGb
if ($null -eq $gpu) {
  Write-Warn 'nvidia-smi does not answer: no NVIDIA GPU found, or no driver installed.'
  Write-Info 'The stand is built for NVIDIA with CUDA. Without it the model runs on the CPU, 20-50 times slower.'
  $gpu = @{ name = 'unknown'; gb = 8 }
} else {
  Write-Ok '{0}, {1} GB of VRAM' $gpu.name $gpu.gb
}

Write-Step 'models that fit'
$fits = $catalog | Where-Object { $_.vramGb -le $gpu.gb }
foreach ($m in $catalog) {
  $mark = if ($m.vramGb -le $gpu.gb) { (T 'fits    ') } else { (T 'TOO BIG ') }
  (T '    {0} {1,-38} {2,5} GB file, needs {3,2} GB - {4}' @($mark, $m.name, $m.sizeGb, $m.vramGb, (T $m.note))) | Write-Host
}
if ($ListOnly) { return }

if ($Model) {
  $choice = $catalog | Where-Object { $_.name -eq $Model } | Select-Object -First 1
  if (-not $choice) { throw (T 'model {0} is not in the catalog; place the file yourself and set model.file in config.json' @($Model)) }
} elseif ($fits) {
  $choice = $fits | Sort-Object vramGb -Descending | Select-Object -First 1
} else {
  # Not enough VRAM even for the smallest option: keep it, but say plainly that
  # part of the model spills to the CPU and speed drops.
  $choice = $catalog[0]
  Write-Warn '{0} GB of VRAM is less than the smallest option needs ({1} GB)' $gpu.gb $choice.vramGb
  Write-Info 'Installing it anyway: part of the model will run on the CPU and it will be slow.'
  Write-Info 'Options: shrink the context window in config.json (server.ctx), or take a smaller quant from the same Hugging Face repository.'
}
Write-Ok 'chosen: {0} (window {1} tokens)' $choice.name $choice.ctx

$target = Join-Path $modelsDir $choice.name
New-Item -ItemType Directory -Force -Path $modelsDir | Out-Null

Write-Step 'model file'
if (Test-Path $target) {
  $have = [math]::Round((Get-Item $target).Length / 1GB, 1)
  Write-Ok 'already downloaded ({0} GB): {1}' $have $target
} elseif ($NoDownload) {
  Write-Info 'download it by hand and place it into {0}:' $modelsDir
  Write-Info '  https://huggingface.co/{0}  ->  {1}' $choice.repo $choice.name
} else {
  Write-Info 'downloading {0} (~{1} GB) from {2}' $choice.name $choice.sizeGb $choice.repo
  $url = "https://huggingface.co/$($choice.repo)/resolve/main/$($choice.name)?download=true"
  # curl.exe ships with Windows 10+ and can resume (-C -), unlike Invoke-WebRequest
  & curl.exe -L --fail --retry 5 --retry-delay 5 -C - -o "$target" "$url"
  if ($LASTEXITCODE -ne 0) {
    Write-Warn 'the automatic download failed (network/mirror). Download the file by hand:'
    Write-Info '  https://huggingface.co/{0}' $choice.repo
    Write-Info '  and place it into {0}' $modelsDir
    throw (T 'the model was not downloaded')
  }
  Write-Ok 'downloaded: {0}' $target
}

Write-Step 'image projector (optional)'
$mmproj = Join-Path $modelsDir 'mmproj-F16.gguf'
if (Test-Path $mmproj) {
  Write-Ok 'already in place'
} elseif (-not $NoDownload) {
  $url = "https://huggingface.co/$($choice.repo)/resolve/main/mmproj-F16.gguf?download=true"
  & curl.exe -L --fail --retry 3 -C - -o "$mmproj" "$url" 2>$null
  if ($LASTEXITCODE -eq 0) { Write-Ok 'downloaded - the stand will see images' }
  else { Remove-Item -Force $mmproj -ErrorAction SilentlyContinue; Write-Info 'this model has no projector - images will not be available' }
}

Write-Step 'writing the choice into config.json'
Set-StandConfig @{
  'model.file' = $choice.name
  'model.repo' = $choice.repo
  'model.path' = $target
  'model.mtp'  = $choice.mtp
  'server.ctx' = $choice.ctx
}
Write-Ok 'written'

Write-Done 'model ready. Next: windows\30-tune.ps1 sizes the window for your VRAM and measures the speed'
