# Мастер модели: подобрать под видеокарту, скачать, проверить.
#
# Запуск:  powershell -ExecutionPolicy Bypass -File windows\20-model.ps1
# Ключи:   -ListOnly   только показать таблицу и выйти
#          -Model <имя файла>  взять конкретный файл, без подбора
#          -NoDownload только записать выбор в config.json (файл положите сами)
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

# Каталог проверенных вариантов. vramGb — СКОЛЬКО НУЖНО видеопамяти, чтобы
# модель влезла целиком вместе с окном контекста; sizeGb — размер файла.
# Каталог: сначала семейство, потом кванты от крупного к мелкому. Мастер берёт
# самый крупный квант, который влезает в видеопамять вместе с окном контекста;
# если не влезает ни один — предлагает тот же файл поменьше, а не другую модель.
#
# vramGb — сколько всего видеопамяти нужно (вес модели + кэш контекста + буферы).
# mtp    — модель умеет предсказывать несколько токенов вперёд (--spec-type
#          draft-mtp): это +50-100% к скорости генерации, поэтому такие варианты
#          в приоритете.
$catalog = @(
  @{ name='Qwen3.5-9B-MTP-UD-Q4_K_XL.gguf';  repo='unsloth/Qwen3.5-9B-MTP-GGUF';  vramGb=10; sizeGb=6.1;  ctx=32768; mtp=$true;  family='Qwen3.5 9B'; note='самый скромный вариант: 10 ГБ видеопамяти' }
  @{ name='Qwen3.5-9B-MTP-UD-Q5_K_XL.gguf';  repo='unsloth/Qwen3.5-9B-MTP-GGUF';  vramGb=12; sizeGb=6.9;  ctx=49152; mtp=$true;  family='Qwen3.5 9B'; note='минимальная рекомендуемая конфигурация' }
  @{ name='Qwen3.5-9B-MTP-UD-Q6_K_XL.gguf';  repo='unsloth/Qwen3.5-9B-MTP-GGUF';  vramGb=14; sizeGb=9.0;  ctx=65536; mtp=$true;  family='Qwen3.5 9B'; note='то же семейство, выше точность' }
  @{ name='Qwen3.8-27B-UD-Q3_K_XL.gguf';     repo='unsloth/Qwen3.8-27B-GGUF';     vramGb=16; sizeGb=13;   ctx=65536; mtp=$true;  family='Qwen3.8 27B'; note='конфигурация автора (RTX 5080, 16 ГБ)' }
  @{ name='Qwen3.8-27B-UD-Q4_K_XL.gguf';     repo='unsloth/Qwen3.8-27B-GGUF';     vramGb=24; sizeGb=17;   ctx=65536; mtp=$true;  family='Qwen3.8 27B'; note='та же модель, точнее' }
  @{ name='Qwen3.8-27B-Q5_K_M.gguf';         repo='unsloth/Qwen3.8-27B-GGUF';     vramGb=32; sizeGb=21;   ctx=131072; mtp=$true; family='Qwen3.8 27B'; note='для карт 32 ГБ и больше' }
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

Write-Step 'видеокарта'
$gpu = Get-VramGb
if ($null -eq $gpu) {
  Write-Warn 'nvidia-smi не отвечает: видеокарта NVIDIA не найдена или не установлен драйвер.'
  Write-Info 'Стенд рассчитан на NVIDIA с CUDA. Без неё модель пойдёт на процессоре — это в 20–50 раз медленнее.'
  $gpu = @{ name = 'неизвестно'; gb = 8 }
} else {
  Write-Ok "$($gpu.name), $($gpu.gb) ГБ видеопамяти"
}

Write-Step 'подходящие модели'
$fits = $catalog | Where-Object { $_.vramGb -le $gpu.gb }
foreach ($m in $catalog) {
  $mark = if ($m.vramGb -le $gpu.gb) { 'подходит  ' } else { 'НЕ влезет ' }
  '    {0} {1,-38} {2,5} ГБ файл, нужно {3,2} ГБ — {4}' -f $mark, $m.name, $m.sizeGb, $m.vramGb, $m.note | Write-Host
}
if ($ListOnly) { return }

if ($Model) {
  $choice = $catalog | Where-Object { $_.name -eq $Model } | Select-Object -First 1
  if (-not $choice) { throw "модель $Model не из каталога; положите файл сами и укажите model.file в config.json" }
} elseif ($fits) {
  $choice = $fits | Sort-Object vramGb -Descending | Select-Object -First 1
} else {
  # Видеопамяти мало даже под самый скромный вариант: берём его же, но честно
  # предупреждаем — часть модели уйдёт на процессор и скорость упадёт.
  $choice = $catalog[0]
  Write-Warn "видеопамяти $($gpu.gb) ГБ — меньше, чем нужно самому скромному варианту ($($choice.vramGb) ГБ)"
  Write-Info 'Ставлю его же: модель частично пойдёт на процессор, работать будет медленно.'
  Write-Info 'Варианты: уменьшить окно контекста в config.json (server.ctx) или взять квант мельче в том же репозитории Hugging Face.'
}
Write-Ok "выбрана: $($choice.name) (окно $($choice.ctx) токенов)"

$target = Join-Path $modelsDir $choice.name
New-Item -ItemType Directory -Force -Path $modelsDir | Out-Null

Write-Step 'файл модели'
if (Test-Path $target) {
  $have = [math]::Round((Get-Item $target).Length / 1GB, 1)
  Write-Ok "уже скачан ($have ГБ): $target"
} elseif ($NoDownload) {
  Write-Info "скачайте вручную и положите в $modelsDir :"
  Write-Info "  https://huggingface.co/$($choice.repo)  →  $($choice.name)"
} else {
  Write-Info "скачиваю $($choice.name) (~$($choice.sizeGb) ГБ) из $($choice.repo)"
  $url = "https://huggingface.co/$($choice.repo)/resolve/main/$($choice.name)?download=true"
  # curl.exe есть в Windows 10+; он умеет докачку (-C -), в отличие от Invoke-WebRequest
  & curl.exe -L --fail --retry 5 --retry-delay 5 -C - -o "$target" "$url"
  if ($LASTEXITCODE -ne 0) {
    Write-Warn 'автоматическая загрузка не удалась (сеть/зеркало). Скачайте файл вручную:'
    Write-Info "  https://huggingface.co/$($choice.repo)"
    Write-Info "  и положите в $modelsDir"
    throw 'модель не скачана'
  }
  Write-Ok "скачано: $target"
}

Write-Step 'проектор для картинок (необязательно)'
$mmproj = Join-Path $modelsDir 'mmproj-F16.gguf'
if (Test-Path $mmproj) {
  Write-Ok 'уже на месте'
} elseif (-not $NoDownload) {
  $url = "https://huggingface.co/$($choice.repo)/resolve/main/mmproj-F16.gguf?download=true"
  & curl.exe -L --fail --retry 3 -C - -o "$mmproj" "$url" 2>$null
  if ($LASTEXITCODE -eq 0) { Write-Ok 'скачан — стенд будет видеть картинки' }
  else { Remove-Item -Force $mmproj -ErrorAction SilentlyContinue; Write-Info 'у этой модели проектора нет — картинки будут недоступны' }
}

Write-Step 'запись выбора в config.json'
Set-StandConfig @{
  'model.file' = $choice.name
  'model.repo' = $choice.repo
  'model.path' = $target
  'model.mtp'  = $choice.mtp
  'server.ctx' = $choice.ctx
}
Write-Ok 'записано'

Write-Done "модель готова. Дальше: windows\30-tune.ps1 — подберёт окно под вашу VRAM и проверит скорость"
