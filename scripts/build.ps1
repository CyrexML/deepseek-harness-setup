# Build llama.cpp for sm_120 with CUDA 12.8.
# decision-01 s4: delete build/ entirely before every rebuild --
# GGML_CUDA_FORCE_CUBLAS sticks in CMakeCache.txt and silently disables MMQ.
# decision-01 s8.5: MSVC 17.14 fails nvcc's host-compiler version check;
# -allow-unsupported-compiler bypasses it. If measurements later look odd,
# rebuild on a supported toolset BEFORE blaming llama.cpp config.
$ErrorActionPreference = "Continue"
$src = "F:\Harness_AI\llama.cpp"
$log = "F:\Harness_AI\run\build.log"
if (Test-Path $log) { Remove-Item -Force $log }
function Say($m) { $s = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m; Write-Host $s; Add-Content -Path $log -Value $s }

$cuda = Get-ChildItem "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name | Select-Object -Last 1
if (-not $cuda) { Say "CUDA toolkit not found"; exit 1 }
$nvcc = Join-Path $cuda.FullName "bin\nvcc.exe"
Say ("cuda = " + $cuda.FullName)

# WSL interop hands Windows processes an environment snapshot taken when WSL
# started, so CUDA_PATH* set by the installer are invisible here. MSBuild's
# CUDA targets resolve CudaToolkitDir from them and fail with
# "The CUDA Toolkit v12.8 directory '' does not exist". Re-read from registry.
foreach ($n in @("CUDA_PATH", "CUDA_PATH_V12_8")) {
    $v = [Environment]::GetEnvironmentVariable($n, "Machine")
    if ($v) { Set-Item -Path ("Env:" + $n) -Value $v; Say ($n + " = " + $v) }
}
if (-not $env:CUDA_PATH) { $env:CUDA_PATH = $cuda.FullName; Say ("CUDA_PATH forced = " + $env:CUDA_PATH) }
$env:PATH = (Join-Path $cuda.FullName "bin") + ";" + $env:PATH
& $nvcc --version 2>&1 | Select-Object -Last 2 | ForEach-Object { Say ("nvcc: " + $_) }

$cmake = "C:\Program Files\CMake\bin\cmake.exe"
if (-not (Test-Path $cmake)) {
    $cmake = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
}
Say ("cmake = " + $cmake)

if (Test-Path "$src\build") { Say "removing stale build/ (CMakeCache trap, decision-01 s4)"; Remove-Item -Recurse -Force "$src\build" }

Say "=== CONFIGURE ==="
& $cmake -B "$src\build" -S $src `
    -T ("cuda=" + $cuda.FullName) `
    -DGGML_CUDA=ON `
    -DCMAKE_CUDA_ARCHITECTURES=120 `
    -DGGML_CUDA_FORCE_CUBLAS=OFF `
    -DLLAMA_CURL=OFF `
    -DCMAKE_CUDA_COMPILER="$nvcc" `
    -DCMAKE_CUDA_FLAGS="-allow-unsupported-compiler" 2>&1 |
    ForEach-Object { Add-Content -Path $log -Value $_; Write-Host $_ }
$rc = $LASTEXITCODE
Say ("configure exit = " + $rc)
if ($rc -ne 0) { Say "CONFIGURE FAILED"; Say "=== BUILD SCRIPT DONE ==="; exit 1 }

Say "=== BUILD ==="
& $cmake --build "$src\build" --config Release --target llama-server llama-cli llama-bench --parallel 16 2>&1 |
    ForEach-Object { Add-Content -Path $log -Value $_; Write-Host $_ }
Say ("build exit = " + $LASTEXITCODE)

$exe = "$src\build\bin\Release\llama-server.exe"
if (Test-Path $exe) { Say ("OK: " + $exe + " (" + (Get-Item $exe).Length + " bytes)") }
else { Say "llama-server.exe WAS NOT BUILT" }
Say "=== BUILD SCRIPT DONE ==="
