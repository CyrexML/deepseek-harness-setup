# Auto-tune llama-server for the local GPU, then measure the result.
#
#   powershell -ExecutionPolicy Bypass -File windows\30-tune.ps1
#   ... -CheckOnly    change nothing, only measure the current state
#   ... -ReserveMb 6000   keep 6 GB of VRAM free for your own GPU work
#                         (training, Stable Diffusion, rendering): the context
#                         window is computed from what is left
#
# It computes the context window that fits into free VRAM, writes the values into
# config.json, generates run\start-server.ps1 from them, starts the server and
# prints prefill and generation speed.
[CmdletBinding()]
param([switch]$CheckOnly, [int]$ReserveMb = 0)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\lib.ps1"

$cfg = Read-StandConfig
$root = $cfg.windowsRoot
$modelPath = if ($cfg.model.PSObject.Properties['path']) { $cfg.model.path } else { Join-Path $root "models\$($cfg.model.file)" }
if (-not (Test-Path $modelPath)) { throw "нет файла модели: $modelPath (сначала windows\20-model.ps1)" }

function Get-FreeVramMb {
  try { [int]((& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1)) }
  catch { 0 }
}

if (-not $CheckOnly) {
  Write-Step 'подбор окна контекста'
  $vramMb = Get-FreeVramMb
  $modelMb = [int]((Get-Item $modelPath).Length / 1MB)
  # Headroom for CUDA itself, compute buffers and the image projector: about
  # 1200 MiB beyond weights and cache, measured on an RTX 5080 (16 GB).
  $overheadMb = 1200
  # -ReserveMb keeps VRAM away from the model. The default 0 lets the window take
  # everything, leaving 150-500 MiB free - far too little for your own GPU work,
  # and llama-server holds what it allocated for as long as it runs.
  $budgetMb = $vramMb - $modelMb - $overheadMb - $ReserveMb
  if ($ReserveMb -gt 0) { Write-Info "отложено под ваши задачи на GPU: $ReserveMb МиБ" }
  # KV cache at q4_0 compression, measured rather than derived: a 64k window
  # costs ~1500 MiB on a 27B model, hence this linear estimate.
  $mbPer1k = 23
  $ctx = [math]::Floor($budgetMb / $mbPer1k) * 1024
  foreach ($cap in @(131072, 98304, 65536, 49152, 32768, 16384, 8192)) {
    if ($ctx -ge $cap) { $ctx = $cap; break }
  }
  if ($ctx -lt 8192) {
    $ctx = 8192
    if ($ReserveMb -gt 0) { Write-Warn "с запасом $ReserveMb МиБ окно ужалось до 8k. Для своих задач на GPU лучше взять модель поменьше (docs/MODEL.md §2)" }
    else { Write-Warn 'видеопамяти впритык: окно 8k. Возьмите квант поменьше (docs/MODEL.md §2)' }
  }
  Write-Ok "видеопамять $vramMb МиБ, модель $modelMb МиБ → окно $ctx токенов"
  Set-StandConfig @{ 'server.ctx' = $ctx }
  $cfg = Read-StandConfig

  Write-Step 'команда запуска (run\start-server.ps1)'
  $runDir = Join-Path $root 'run'
  New-Item -ItemType Directory -Force -Path $runDir | Out-Null
  $tpl = Get-Content (Join-Path $script:StandRoot 'templates\start-server.ps1.tmpl') -Raw -Encoding UTF8
  $mmproj = Join-Path $root 'models\mmproj-F16.gguf'
  $jinja  = Join-Path $root 'models\chat-agent.jinja'
  $tpl = $tpl.
    Replace('@MODEL_PATH@', $modelPath).
    Replace('@ROOT@',       $root).
    Replace('@CTX@',        "$($cfg.server.ctx)").
    Replace('@CACHE@',      "$($cfg.server.cacheType)").
    Replace('@SPEC_NMAX@',  "$($cfg.server.specDraftNMax)").
    Replace('@MTP@',        $(if ($cfg.model.PSObject.Properties['mtp'] -and -not $cfg.model.mtp) { '$false' } else { '$true' })).
    Replace('@MMPROJ@',     $(if (Test-Path $mmproj) { $mmproj } else { '' })).
    Replace('@JINJA@',      $(if (Test-Path $jinja)  { $jinja }  else { '' })).
    Replace('@PORT@',       "$($cfg.modelPort)").
    Replace('@EFFORT@',     "$($cfg.server.reasoningEffort)").
    Replace('@BUDGET@',     "$($cfg.server.reasoningBudget)")
  Set-Content -Path (Join-Path $runDir 'start-server.ps1') -Value $tpl -Encoding UTF8
  Copy-Item (Join-Path $script:StandRoot 'templates\stop-server.ps1.tmpl') (Join-Path $runDir 'stop-server.ps1') -Force
  ((Get-Content (Join-Path $runDir 'stop-server.ps1') -Raw) -replace '@ROOT@', $root) |
    Set-Content -Path (Join-Path $runDir 'stop-server.ps1') -Encoding UTF8
  Write-Ok 'записана'
}

Write-Step 'перезапуск сервера'
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'run\stop-server.ps1') | Out-Null
Start-Sleep -Seconds 3
Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'run\start-server.ps1')) -WindowStyle Hidden
$url = "http://127.0.0.1:$($cfg.modelPort)"
$deadline = (Get-Date).AddMinutes(8)
do {
  Start-Sleep -Seconds 5
  $health = try { (Invoke-RestMethod -Uri "$url/health" -TimeoutSec 5 -ErrorAction Stop).status } catch { '' }
} until ($health -eq 'ok' -or (Get-Date) -gt $deadline)
if ($health -ne 'ok') { throw "сервер не поднялся за 8 минут — смотрите $root\run\server.log" }
Write-Ok 'поднят'

Write-Step 'замер (первый запрос всегда медленнее — это прогрев)'
$body = @{ prompt = ('The quick brown fox jumps over the lazy dog near the river bank. ' * 500).Substring(0, 32000)
           n_predict = 1; temperature = 0; cache_prompt = $false; stream = $false } | ConvertTo-Json
Invoke-RestMethod -Uri "$url/completion" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 600 | Out-Null
$r1 = Invoke-RestMethod -Uri "$url/completion" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 600
$body2 = @{ prompt = 'Explain what a neural network is, in two sentences.'
            n_predict = 256; temperature = 0; cache_prompt = $false; stream = $false } | ConvertTo-Json
$r2 = Invoke-RestMethod -Uri "$url/completion" -Method Post -Body $body2 -ContentType 'application/json' -TimeoutSec 600

$prefill = [math]::Round($r1.timings.prompt_per_second)
$decode  = [math]::Round($r2.timings.predicted_per_second)
$freeMb  = try { [int]((& nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null | Select-Object -First 1)) } catch { 0 }

Write-Host ''
Write-Host "  модель:        $(Split-Path -Leaf $modelPath)"
Write-Host "  окно:          $($cfg.server.ctx) токенов"
Write-Host "  префилл:       $prefill ток/с   (на RTX 5080, 16 ГБ — около 1970)"
Write-Host "  генерация:     $decode ток/с   (на RTX 5080, 16 ГБ — около 95)"
Write-Host "  свободно VRAM: $freeMb МиБ"
Write-Host ''
if ($decode -lt 20) {
  Write-Warn 'генерация ниже 20 ток/с — модель почти наверняка не влезла в видеопамять.'
  Write-Info 'Возьмите квант поменьше (docs/MODEL.md §2) или запустите этот скрипт ещё раз: он пересчитает окно.'
} else {
  Write-Done 'настройка модели закончена'
}
