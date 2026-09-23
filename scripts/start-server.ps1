# Launch llama-server. Profile is parameterised.
# -lv 4 (trace) is required to see 'chat format:' (SRV_TRC) and
# 'forcing full prompt re-processing' (SLT_TRC) -- decision-01 s8.1.
# Per s8.2 timings must be taken WITHOUT trace: pass -Verbosity 3.
param(
  # 64k window with a q4_0 KV cache: q4_0 keeps the MMA_F16 tensor kernel, while
  # q4_1 is not supported by FlashAttention in this build.
  [int]$Ctx        = 65536,
  [string]$CacheK  = "q4_0",
  [string]$CacheV  = "q4_0",
  # switch, not [bool]: in -File mode PowerShell passes "-Mtp:$false" as the
  # literal string "$false", which cannot convert to Boolean. MTP is on by
  # default; pass -NoMtp to turn it off (needed for test 5.0 and the 5.4 baseline).
  [switch]$NoMtp,
  # 3 draft tokens is the peak before the cliff: 4 on a 64k window drops prefill
  # from 1871 to 763 tok/s because VRAM spills.
  [int]$SpecNMax   = 3,
  [int]$CtxCheckpoints = 32,
  # "medium" sends NO thinking instruction, "low" sends "Keep your thinking brief
  # and focused". The hard ceiling is ReasoningBudget: measured across three
  # sessions, the median step spends 150-300 reasoning tokens, but 8-16% of steps
  # hit the cap and produce about 40% of all reasoning.
  [string]$ReasoningEffort = "medium",
  [int]$ReasoningBudget = 5000,
  # Custom jinja instead of the one baked into the GGUF. --no-reasoning-preserve
  # does NOT work in an agent loop: the stock template keeps reasoning for every
  # assistant message after the last user message, and tool results have
  # role=tool, so the "last user" is the turn prompt and the reasoning of all
  # 50-80 steps is replayed in every request - measured at 48-60% of everything
  # entering the window. The stand's template adds `and not loop.last`, so only
  # the latest answer keeps its reasoning. Verify with POST /apply-template using
  # two assistant messages carrying reasoning_content: neither text may come back.
  # An empty string falls back to the stock GGUF template.
  [string]$ChatTemplateFile = "F:\Harness_AI\models\qwen3.8-agent.jinja",
  [int]$Port       = 8080,
  [string]$Log     = "F:\Harness_AI\run\server.log",
  [int]$Verbosity  = 3,
  [string]$Bind    = "0.0.0.0",
  # DRY sampler, off by default.
  #
  # DryPenaltyLastN: the build default of 64 tokens cannot see a loop at all -
  # a repeated paragraph is 80-120 tokens. 2048 covers several repetitions.
  [switch]$Dry,
  [double]$DryMultiplier   = 0.8,
  [double]$DryBase         = 1.75,
  [int]$DryAllowedLength   = 4,
  [int]$DryPenaltyLastN    = 2048,
  # Multimodal projector.
  #
  # MmprojDevice "none" keeps the projector on the CPU: on a 64k window about
  # 539 MiB of VRAM are free and the projector weighs 885 MiB, so it does not
  # fit. An empty Mmproj means no vision at all.
  [string]$Mmproj = "F:\Harness_AI\models\mmproj-F16.gguf",
  [string]$MmprojDevice = "none",
  # Sampling. The types are [string] rather than [double] on purpose: PS 5.1
  # formats [double] using the current culture, so in a comma locale "0,9" would
  # reach the exe and be read as 0. A string also preserves "0.90" exactly.
  # Running this script without parameters gives the same server the launcher
  # starts.
  [string]$Temp   = "1.0",
  [string]$TopP   = "0.95",
  [string]$TopK   = "20",
  [string]$MinP   = "0.0",
  # Penalties. An empty string means the flag is not passed at all, i.e. the
  # build defaults (presence 0.0, repeat 1.0). Qwen recommends presence 1.5 for
  # the non-thinking mode.
  [string]$PresencePenalty = "",
  [string]$RepeatPenalty   = "",
  # Plain mode instead of thinking. The template checks
  # `enable_thinking is undefined or enable_thinking is true`, so it is turned
  # off with an explicit false in chat-template-kwargs. Qwen recommends
  # temp 0.7, top-p 0.80, top-k 20, min-p 0.0, presence 1.5 for this mode.
  [switch]$NoThinking,
  # Extra llama-server flags, for experiments rather than for the working setup:
  # whatever a measurement proves is worth keeping moves up into an explicit
  # parameter. A string, not [string[]]: in -File mode PowerShell joins
  # "-Extra -b,1024,-ub,1024" into ONE element which llama-server rejects
  # wholesale, so the split by spaces happens here.

  # Only print the command line and exit (configuration check).
  [switch]$PrintOnly
)

# WSL interop hands Windows processes an environment snapshot taken when WSL
# started. Anything installed since -- including CUDA's addition to PATH -- is
# invisible here, and llama-server.exe then dies with STATUS_DLL_NOT_FOUND
# (0xC0000135). Read Windows variables from the registry, never from $env:.
$cudaPath = [Environment]::GetEnvironmentVariable("CUDA_PATH", "Machine")
if ($cudaPath) { $env:PATH = (Join-Path $cudaPath "bin") + ";" + $env:PATH }

$exe   = "F:\Harness_AI\llama.cpp\build\bin\Release\llama-server.exe"
$model = "F:\Harness_AI\models\Qwen3.8-27B-UD-Q3_K_XL.gguf"

if (-not (Test-Path $exe))   { Write-Error "missing $exe";   exit 1 }
if (-not (Test-Path $model)) { Write-Error "missing $model"; exit 1 }

# No spaces inside the JSON: PowerShell both strips inner quotes and splits the
# argument on spaces when passing it to a native exe.
if ($NoThinking) {
  $ctk = "{\`"reasoning_effort\`":\`"$ReasoningEffort\`",\`"enable_thinking\`":false}"
} else {
  $ctk = "{\`"reasoning_effort\`":\`"$ReasoningEffort\`"}"
}

$a = @(
  "-m", $model,
  "--jinja",
  "-ngl", "99", "--fit", "off",
  "-c", "$Ctx",
  "--cache-type-k", $CacheK, "--cache-type-v", $CacheV,
  # decision-07 s3: "--ctx-checkpoints 0" removed. RFC s3 justified it with a
  # claim that checkpoints are always invalidated on hybrid models; false for
  # this build -- on a request that diverges from the KV they cut prefill 18x.
  # 32 is the llama.cpp default.
  "--ctx-checkpoints", "$CtxCheckpoints",
  "--parallel", "1",
  # PS 5.1 strips inner double quotes when passing to a native exe, so the JSON
  # arrives as {preserve_thinking: ...} and llama-server rejects it. Escape them.
  # No spaces inside the JSON: PS 5.1 both strips inner quotes AND splits the
  # argument on whitespace when handing it to a native exe. Escaped quotes fix
  # the first, removing spaces fixes the second.
  #
  # "preserve_thinking" from RFC s3 is a NO-OP on this build. The server reads
  # "preserve_reasoning" (arg.cpp:964) and enables it by default when absent;
  # preserve_thinking is only the internal jinja variable name (caps.cpp:23).
  # Setting it via --chat-template-kwargs is deprecated anyway, so reasoning
  # preservation is turned off through the dedicated flag below.
  "--chat-template-kwargs", $ctk,
  "--no-reasoning-preserve",
  "--reasoning-budget", "$ReasoningBudget",
  "--temp", $Temp, "--top-p", $TopP, "--top-k", $TopK, "--min-p", $MinP,
  "--host", $Bind, "--port", "$Port",
  "-lv", "$Verbosity"
)
if (-not $NoMtp) { $a += @("--spec-type", "draft-mtp", "--spec-draft-n-max", "$SpecNMax") }
if ($ChatTemplateFile) {
  if (-not (Test-Path $ChatTemplateFile)) { Write-Error "missing $ChatTemplateFile"; exit 1 }
  $a += @("--chat-template-file", $ChatTemplateFile)
}

if ($PresencePenalty) { $a += @("--presence-penalty", $PresencePenalty) }
if ($RepeatPenalty)   { $a += @("--repeat-penalty",   $RepeatPenalty) }

if ($Mmproj) {
  if (-not (Test-Path $Mmproj)) { Write-Error "missing $Mmproj"; exit 1 }
  $a += @("--mmproj", $Mmproj)
  # "auto" in the help text describes the default rather than being a valid
  # value: the server rejects it with "invalid device: auto". An empty string
  # means the flag is not passed, i.e. the projector goes to the GPU.
  if ($MmprojDevice) { $a += @("--mmproj-device", $MmprojDevice) }
}

# Numbers are passed as strings: PS 5.1 formats [double] using the current
# culture, so in a comma locale "0,8" would reach the exe and be read as 0.
if ($Extra) { $a += ($Extra -split ' +' | Where-Object { $_ }) }

if ($Dry) {
  $a += @(
    "--dry-multiplier",     ([string]::Format([cultureinfo]::InvariantCulture, "{0}", $DryMultiplier)),
    "--dry-base",           ([string]::Format([cultureinfo]::InvariantCulture, "{0}", $DryBase)),
    "--dry-allowed-length", "$DryAllowedLength",
    "--dry-penalty-last-n", "$DryPenaltyLastN"
  )
}

Write-Host ("EXEC: " + $exe + " " + ($a -join " "))
if ($PrintOnly) { exit 0 }
if (Test-Path $Log) { Remove-Item -Force $Log }
Write-Host ("LOG:  " + $Log)

# llama-server writes its log to stderr
$p = Start-Process -FilePath $exe -ArgumentList $a -NoNewWindow -PassThru `
       -RedirectStandardOutput "$Log.out" -RedirectStandardError $Log
Write-Host ("PID: " + $p.Id)
$p.Id | Out-File -Encoding ascii "F:\Harness_AI\run\server.pid"
