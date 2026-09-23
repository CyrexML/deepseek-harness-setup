# Движок модели: llama.cpp с поддержкой CUDA.
#
#   powershell -ExecutionPolicy Bypass -File windows\10-llama.ps1
#   ... -Build       собрать из исходников (нужен CUDA Toolkit + CMake); обычно НЕ нужно
#   ... -Cpu         принудительно поставить сборку без CUDA
#
# Почему не «просто скачать последний релиз»:
#   * у релизов с номером версии (v0.4.1 и подобных) НЕТ сборок под Windows —
#     они лежат в накатных сборках вида b11132, поэтому релизы перебираются,
#     пока не найдётся подходящий ассет;
#   * сборок под CUDA несколько (12.4 и 13.4) — нужная выбирается по версии
#     драйвера видеокарты, её печатает nvidia-smi;
#   * рядом лежит ОТДЕЛЬНЫЙ архив cudart-… с библиотеками времени выполнения
#     CUDA. Без него llama-server.exe не стартует («не найден cudart64_*.dll»),
#     поэтому он скачивается вместе со сборкой. CUDA Toolkit не нужен —
#     достаточно драйвера NVIDIA.
[CmdletBinding()]
param([switch]$Build, [switch]$Cpu, [string]$Tag = '')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\lib.ps1"

$cfg = Read-StandConfig
$dst = Join-Path $cfg.windowsRoot 'llama.cpp'
$binDir = Join-Path $dst 'build\bin\Release'
$exe = Join-Path $binDir 'llama-server.exe'

# Работоспособность проверяем запуском, а не наличием файла: не хватает
# библиотек CUDA — exe есть, но падает сразу.
function Test-Engine {
    if (-not (Test-Path $exe)) { return $false }
    try {
        $out = & $exe --version 2>&1 | Out-String
        return ($LASTEXITCODE -eq 0) -or ($out -match 'version|llama')
    } catch { return $false }
}

if (Test-Engine) {
    Write-Step 'движок'
    Write-Ok "уже установлен и запускается: $exe"
    Write-Info 'чтобы переустановить — удалите папку llama.cpp и запустите шаг снова'
    return
}

# Максимальная версия CUDA, которую тянет установленный драйвер: nvidia-smi
# печатает её в шапке («CUDA Version: 13.0»). Это НЕ требование поставить
# Toolkit — это потолок драйвера.
function Get-GpuInfo {
    try {
        $header = (& nvidia-smi 2>$null | Out-String)
        if (-not $header) { return $null }
        $cuda = if ($header -match 'CUDA Version:\s*([0-9]+)\.([0-9]+)') { [double]"$($Matches[1]).$($Matches[2])" } else { 0 }
        $name = (& nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1)
        $driver = (& nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>$null | Select-Object -First 1)
        return @{ name = $name; driver = $driver; cuda = $cuda }
    } catch { return $null }
}

Write-Step 'видеокарта и драйвер'
$gpu = if ($Cpu) { $null } else { Get-GpuInfo }
if ($null -eq $gpu) {
    if (-not $Cpu) {
        Write-Warn 'NVIDIA не обнаружена (или нет драйвера) — ставлю сборку под процессор'
        Write-Info 'Модель будет считаться на CPU: это в десятки раз медленнее.'
        Write-Info 'Если карта есть — поставьте свежий драйвер с nvidia.com и запустите шаг заново.'
    }
} else {
    Write-Ok "$($gpu.name), драйвер $($gpu.driver), поддерживает CUDA до $($gpu.cuda)"
}

if ($Build) {
    Write-Step 'сборка из исходников'
    foreach ($tool in @('git', 'cmake')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "нет $tool — поставьте его (winget install Git.Git / Kitware.CMake)" }
    }
    if (-not $env:CUDA_PATH) { throw 'не найден CUDA Toolkit (переменная CUDA_PATH) — он нужен ТОЛЬКО для сборки из исходников' }
    if (-not (Test-Path (Join-Path $dst '.git'))) {
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Write-Info 'клонирую llama.cpp'
        & git clone --depth 1 https://github.com/ggml-org/llama.cpp $dst
    }
    if ($Tag) { & git -C $dst fetch --depth 1 origin tag $Tag; & git -C $dst checkout $Tag }
    Write-Info 'cmake configure (CUDA)'
    & cmake -S $dst -B (Join-Path $dst 'build') -DGGML_CUDA=ON -DLLAMA_CURL=OFF
    Write-Info 'cmake build (десятки минут)'
    & cmake --build (Join-Path $dst 'build') --config Release --target llama-server -j
    if (-not (Test-Engine)) { throw 'сборка не дала работающий llama-server.exe' }
    Write-Ok "собрано: $exe"
    Write-Done 'llama.cpp собран'
    return
}

Write-Step 'поиск готовой сборки под Windows'
$headers = @{ 'User-Agent' = 'harness-stand' }
$releases = if ($Tag) {
    @(Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$Tag" -Headers $headers)
} else {
    Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=15' -Headers $headers
}

# Сборки под Windows лежат не в каждом релизе, поэтому идём по списку сверху вниз.
$pick = $null
foreach ($rel in $releases) {
    $win = $rel.assets | Where-Object { $_.name -match '^llama-.*-bin-win-' -and $_.name -match 'x64\.zip$' }
    if (-not $win) { continue }

    if ($null -ne $gpu) {
        # Из доступных вариантов CUDA берём самый свежий, который тянет драйвер.
        $cudaAssets = $win | Where-Object { $_.name -match 'cuda-([0-9]+\.[0-9]+)-x64\.zip$' } | ForEach-Object {
            [void]($_.name -match 'cuda-([0-9]+\.[0-9]+)-x64\.zip$')
            [pscustomobject]@{ asset = $_; version = [double]$Matches[1] }
        } | Sort-Object version -Descending
        $fit = $cudaAssets | Where-Object { $_.version -le $gpu.cuda } | Select-Object -First 1
        if (-not $fit -and $cudaAssets) {
            $fit = $cudaAssets | Select-Object -Last 1
            Write-Warn "драйвер поддерживает CUDA до $($gpu.cuda), беру минимальную доступную сборку CUDA $($fit.version) — при ошибках обновите драйвер"
        }
        if ($fit) {
            $runtime = $rel.assets | Where-Object { $_.name -eq "cudart-llama-bin-win-cuda-$($fit.version)-x64.zip" } | Select-Object -First 1
            $pick = @{ release = $rel; engine = $fit.asset; runtime = $runtime; kind = "CUDA $($fit.version)" }
            break
        }
    }
    $cpu = $win | Where-Object { $_.name -match 'bin-win-cpu-x64\.zip$' } | Select-Object -First 1
    if ($cpu) { $pick = @{ release = $rel; engine = $cpu; runtime = $null; kind = 'CPU' }; break }
}
if ($null -eq $pick) { throw 'в последних 15 релизах llama.cpp нет сборки под Windows x64 — запустите шаг с ключом -Build' }
Write-Ok "$($pick.release.tag_name), вариант $($pick.kind)"

New-Item -ItemType Directory -Force -Path $binDir | Out-Null

function Get-Asset {
    param($Asset, [string]$What)
    Write-Info "качаю ${What}: $($Asset.name) ($([math]::Round($Asset.size/1MB)) МБ)"
    $zip = Join-Path $env:TEMP $Asset.name
    & curl.exe -L --fail --retry 5 --retry-delay 3 -o $zip $Asset.browser_download_url
    if ($LASTEXITCODE -ne 0) { throw "не удалось скачать $($Asset.name)" }
    Expand-Archive -Path $zip -DestinationPath $binDir -Force
    Remove-Item $zip -Force
}

Write-Step 'установка'
Get-Asset -Asset $pick.engine -What 'движок'
if ($pick.runtime) {
    # Библиотеки времени выполнения CUDA идут отдельным архивом; без них exe
    # не стартует. Toolkit при этом не нужен.
    Get-Asset -Asset $pick.runtime -What 'библиотеки CUDA'
} elseif ($pick.kind -ne 'CPU') {
    Write-Warn "в релизе нет архива cudart для $($pick.kind) — если сервер не запустится, поставьте CUDA Toolkit или выберите другой релиз ключом -Tag"
}

# В некоторых архивах файлы лежат в подпапке — поднимаем наверх.
if (-not (Test-Path $exe)) {
    $nested = Get-ChildItem $binDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'llama-server.exe') } | Select-Object -First 1
    if ($nested) {
        Get-ChildItem $nested.FullName | Move-Item -Destination $binDir -Force
        Remove-Item $nested.FullName -Recurse -Force
    }
}
if (-not (Test-Path $exe)) { throw "в архиве нет llama-server.exe — распакуйте вручную в $binDir" }

Write-Step 'проверка запуска'
if (-not (Test-Engine)) {
    Write-Warn 'llama-server.exe установлен, но не запускается.'
    Write-Info 'Обычно это значит, что не хватает библиотек CUDA или драйвер слишком старый.'
    Write-Info 'Попробуйте: обновить драйвер NVIDIA; либо поставить сборку под процессор — этот же шаг с ключом -Cpu.'
    throw 'движок не проходит проверку запуска'
}
Write-Ok 'запускается'
Write-Done "llama.cpp установлен: $exe"
