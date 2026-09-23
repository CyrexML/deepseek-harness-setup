# Model engine: llama.cpp with CUDA support.
#
#   powershell -ExecutionPolicy Bypass -File windows\10-llama.ps1
#   ... -Build       build from source (needs CUDA Toolkit + CMake); normally NOT needed
#   ... -Cpu         force a build without CUDA
#
# Why not "just download the latest release":
#   * version-numbered releases carry no Windows binaries - those live in rolling
#     builds like b11132, so releases are scanned until a usable asset appears;
#   * several CUDA builds exist (12.4 and 13.4) and the right one follows the
#     driver version that nvidia-smi reports;
#   * the CUDA runtime ships as a SEPARATE cudart- archive; without it
#     llama-server.exe fails to start with a missing cudart64_*.dll, so it is
#     downloaded alongside. The CUDA Toolkit is not needed, only the driver.
[CmdletBinding()]
param([switch]$Build, [switch]$Cpu, [string]$Tag = '')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here\lib.ps1"

$cfg = Read-StandConfig
$dst = Join-Path $cfg.windowsRoot 'llama.cpp'
$binDir = Join-Path $dst 'build\bin\Release'
$exe = Join-Path $binDir 'llama-server.exe'

# Health is checked by running the binary, not by its presence: with CUDA
# libraries missing the exe exists but dies immediately.
function Test-Engine {
    if (-not (Test-Path $exe)) { return $false }
    try {
        $out = & $exe --version 2>&1 | Out-String
        return ($LASTEXITCODE -eq 0) -or ($out -match 'version|llama')
    } catch { return $false }
}

if (Test-Engine) {
    Write-Step 'engine'
    Write-Ok 'already installed and starts: {0}' $exe
    Write-Info 'to reinstall, delete the llama.cpp folder and run this step again'
    return
}

# Highest CUDA version the installed driver supports; nvidia-smi prints it in
# its header ("CUDA Version: 13.0"). This is the driver's ceiling, not a
# requirement to install the Toolkit.
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

Write-Step 'GPU and driver'
$gpu = if ($Cpu) { $null } else { Get-GpuInfo }
if ($null -eq $gpu) {
    if (-not $Cpu) {
        Write-Warn 'no NVIDIA GPU (or no driver) - installing the CPU build'
        Write-Info 'The model will run on the CPU: tens of times slower.'
        Write-Info 'If you do have a card, install a current driver from nvidia.com and run this step again.'
    }
} else {
    Write-Ok '{0}, driver {1}, supports CUDA up to {2}' $gpu.name $gpu.driver $gpu.cuda
}

if ($Build) {
    Write-Step 'building from source'
    foreach ($tool in @('git', 'cmake')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw (T 'no {0} - install it (winget install Git.Git / Kitware.CMake)' @($tool)) }
    }
    if (-not $env:CUDA_PATH) { throw (T 'CUDA Toolkit not found (CUDA_PATH) - it is needed ONLY for building from source') }
    if (-not (Test-Path (Join-Path $dst '.git'))) {
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Write-Info 'cloning llama.cpp'
        & git clone --depth 1 https://github.com/ggml-org/llama.cpp $dst
    }
    if ($Tag) { & git -C $dst fetch --depth 1 origin tag $Tag; & git -C $dst checkout $Tag }
    Write-Info 'cmake configure (CUDA)'
    & cmake -S $dst -B (Join-Path $dst 'build') -DGGML_CUDA=ON -DLLAMA_CURL=OFF
    Write-Info 'cmake build (tens of minutes)'
    & cmake --build (Join-Path $dst 'build') --config Release --target llama-server -j
    if (-not (Test-Engine)) { throw (T 'the build produced no working llama-server.exe') }
    Write-Ok 'built: {0}' $exe
    Write-Done 'llama.cpp built'
    return
}

Write-Step 'looking for a prebuilt Windows binary'
$headers = @{ 'User-Agent' = 'harness-stand' }
$releases = if ($Tag) {
    @(Invoke-RestMethod -Uri "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$Tag" -Headers $headers)
} else {
    Invoke-RestMethod -Uri 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=15' -Headers $headers
}

# Not every release carries Windows binaries, so walk the list from the top.
$pick = $null
foreach ($rel in $releases) {
    $win = $rel.assets | Where-Object { $_.name -match '^llama-.*-bin-win-' -and $_.name -match 'x64\.zip$' }
    if (-not $win) { continue }

    if ($null -ne $gpu) {
        # Of the available CUDA builds take the newest one the driver supports.
        $cudaAssets = $win | Where-Object { $_.name -match 'cuda-([0-9]+\.[0-9]+)-x64\.zip$' } | ForEach-Object {
            [void]($_.name -match 'cuda-([0-9]+\.[0-9]+)-x64\.zip$')
            [pscustomobject]@{ asset = $_; version = [double]$Matches[1] }
        } | Sort-Object version -Descending
        $fit = $cudaAssets | Where-Object { $_.version -le $gpu.cuda } | Select-Object -First 1
        if (-not $fit -and $cudaAssets) {
            $fit = $cudaAssets | Select-Object -Last 1
            Write-Warn 'the driver supports CUDA up to {0}; taking the lowest available CUDA {1} build - update the driver if it fails' $gpu.cuda $fit.version
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
if ($null -eq $pick) { throw (T 'no Windows x64 build in the last 15 llama.cpp releases - run this step with -Build') }
Write-Ok '{0}, variant {1}' $pick.release.tag_name $pick.kind

New-Item -ItemType Directory -Force -Path $binDir | Out-Null

function Get-Asset {
    param($Asset, [string]$What)
    Write-Info 'downloading {0}: {1} ({2} MB)' $What $Asset.name ([math]::Round($Asset.size/1MB))
    $zip = Join-Path $env:TEMP $Asset.name
    & curl.exe -L --fail --retry 5 --retry-delay 3 -o $zip $Asset.browser_download_url
    if ($LASTEXITCODE -ne 0) { throw (T 'could not download {0}' @($Asset.name)) }
    Expand-Archive -Path $zip -DestinationPath $binDir -Force
    Remove-Item $zip -Force
}

Write-Step 'installing'
Get-Asset -Asset $pick.engine -What 'движок'
if ($pick.runtime) {
    # The CUDA runtime comes as its own archive; without it the exe will not
    # start. The Toolkit is still not required.
    Get-Asset -Asset $pick.runtime -What 'библиотеки CUDA'
} elseif ($pick.kind -ne 'CPU') {
    Write-Warn 'the release has no cudart archive for {0} - if the server fails to start, install the CUDA Toolkit or pick another release with -Tag' $pick.kind
}

# Some archives nest everything in a subfolder - lift it up.
if (-not (Test-Path $exe)) {
    $nested = Get-ChildItem $binDir -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'llama-server.exe') } | Select-Object -First 1
    if ($nested) {
        Get-ChildItem $nested.FullName | Move-Item -Destination $binDir -Force
        Remove-Item $nested.FullName -Recurse -Force
    }
}
if (-not (Test-Path $exe)) { throw (T 'the archive has no llama-server.exe - unpack it by hand into {0}' @($binDir)) }

Write-Step 'startup check'
if (-not (Test-Engine)) {
    Write-Warn 'llama-server.exe is installed but does not start.'
    Write-Info 'Usually that means missing CUDA libraries or a driver that is too old.'
    Write-Info 'Try: update the NVIDIA driver, or install the CPU build - this same step with -Cpu.'
    throw 'движок не проходит проверку запуска'
}
Write-Ok 'starts'
Write-Done 'llama.cpp installed: {0}' $exe
