# Step 2+3 only: CUDA Toolkit 12.8 (pinned per decision doc s4) and CMake.
# ASCII-only on purpose: PS 5.1 reads .ps1 as ANSI unless BOM; keep it simple.
$ErrorActionPreference = "Continue"
Start-Transcript -Path "F:\Harness_AI\build-setup\install2.log" -Force | Out-Null

function Say($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m) }

Say ("admin = " + ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
Say ("winget = " + (winget --version))

Say "=== [2/3] CUDA Toolkit 12.8 ==="
try {
    winget install --id Nvidia.CUDA --version 12.8 --exact `
        --accept-source-agreements --accept-package-agreements `
        --disable-interactivity --silent
    Say ("cuda winget exit = " + $LASTEXITCODE)
} catch {
    Say ("cuda EXCEPTION: " + $_.Exception.Message)
}

Say "=== [3/3] CMake ==="
try {
    winget install --id Kitware.CMake --exact `
        --accept-source-agreements --accept-package-agreements `
        --disable-interactivity --silent
    Say ("cmake winget exit = " + $LASTEXITCODE)
} catch {
    Say ("cmake EXCEPTION: " + $_.Exception.Message)
}

Say "=== verify ==="
$cudaDir = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA"
if (Test-Path $cudaDir) {
    Get-ChildItem $cudaDir -Directory | ForEach-Object { Say ("CUDA found: " + $_.FullName) }
} else { Say "CUDA NOT INSTALLED" }
if (Test-Path "C:\Program Files\CMake\bin\cmake.exe") { Say "CMake found" } else { Say "CMake NOT INSTALLED" }

Say "=== INSTALL2 DONE ==="
Stop-Transcript | Out-Null
