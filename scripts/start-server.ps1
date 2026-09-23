# Launch llama-server. Profile is parameterised.
# -lv 4 (trace) is required to see 'chat format:' (SRV_TRC) and
# 'forcing full prompt re-processing' (SLT_TRC) -- decision-01 s8.1.
# Per s8.2 timings must be taken WITHOUT trace: pass -Verbosity 3.
param(
  # 64k: замер 2026-09-08. q4_0 на кэше держит тензорное ядро MMA_F16
  # (q4_1 в этой сборке FlashAttention НЕ поддержан — GGML_CUDA_FA_ALL_QUANTS=OFF),
  # префилл на 54k промпта 1536 т/с, удержание 20/20. Прежнее: 32768/q8_0/2.
  [int]$Ctx        = 65536,
  [string]$CacheK  = "q4_0",
  [string]$CacheV  = "q4_0",
  # switch, not [bool]: in -File mode PowerShell passes "-Mtp:$false" as the
  # literal string "$false", which cannot convert to Boolean. MTP is on by
  # default; pass -NoMtp to turn it off (needed for test 5.0 and the 5.4 baseline).
  [switch]$NoMtp,
  # 3 — пик до обрыва: 4 на окне 64k роняет префилл 1871->763 (вытеснение).
  [int]$SpecNMax   = 3,
  [int]$CtxCheckpoints = 32,
  # Шаблон модели: "medium" = НИКАКОЙ инструкции (пустая строка, template §59-70),
  # "low" = «Keep your thinking brief and focused». Жёсткий потолок — ReasoningBudget.
  # Замер 2026-09-11/12 (3 сессии, 1 450 шагов): медиана 150-300 ток./шаг, но
  # 8-16% шагов упираются в 5000 и дают ~40% всего reasoning; reasoning = 73%
  # времени декодирования провальной сессии (199k из 272k ток.).
  [string]$ReasoningEffort = "medium",
  [int]$ReasoningBudget = 5000,
  # Собственный jinja вместо встроенного в GGUF. Пустая строка = флаг не
  # передаётся, командная строка дословно прежняя (правило рук A/B).
  #
  # Зачем: --no-reasoning-preserve в агентном цикле НЕ работает. Шаблон (строка
  # 119) держит reasoning для всех assistant после последнего user; ответы
  # инструментов — role=tool, поэтому «последний user» — это промпт хода, и
  # reasoning всех 50-80 шагов хода уходит в каждый запрос. Замер по usage
  # llama-server: прирост контекста между шагами 285 644 ток. = вывод модели
  # 235 780 + результаты; reasoning — 48-60% всего, что входит в окно.
  # F:\Harness_AI\models\qwen3.8-agent.jinja: та же строка с условием
  # `preserve_thinking is true or (keep_last_thinking is true and last)`.
  # Проверка после запуска: POST /apply-template с двумя assistant-сообщениями
  # с reasoning_content — в ответе не должно быть их текста.
  # 2026-09-15: умолчание = шаблон стенда; "" — стоковый шаблон из GGUF.
  [string]$ChatTemplateFile = "F:\Harness_AI\models\qwen3.8-agent.jinja",
  [int]$Port       = 8080,
  [string]$Log     = "F:\Harness_AI\run\server.log",
  [int]$Verbosity  = 3,
  [string]$Bind    = "0.0.0.0",
  # DRY-семплер (bench-05). ВЫКЛЮЧЕН по умолчанию: без -Dry командная строка
  # обязана совпадать с прежней дословно, иначе рука A замера несопоставима
  # с прошлыми прогонами.
  #
  # DryPenaltyLastN: дефолт сборки -- 64 токена. Повторяющийся абзац занимает
  # 80-120 токенов, то есть окно в 64 петлю физически не видит. 2048 выбрано
  # как окно, покрывающее несколько повторов абзаца.
  [switch]$Dry,
  [double]$DryMultiplier   = 0.8,
  [double]$DryBase         = 1.75,
  [int]$DryAllowedLength   = 4,
  [int]$DryPenaltyLastN    = 2048,
  # Мультимодальный проектор. ВЫКЛЮЧЕН по умолчанию: без -Mmproj командная
  # строка обязана совпадать с прежней дословно, иначе замеры генерации
  # несопоставимы с bench-07 -- то же правило, что у -Dry.
  #
  # MmprojDevice "none" = проектор не выгружается на GPU и считает на CPU.
  # Запас видеопамяти на окне 64k -- 539 МиБ по memory.free, веса проектора
  # 885 МиБ: на GPU они не помещаются (решение 11 §4). "auto" оставлен, чтобы
  # это можно было проверить замером, а не рассуждением.
  # 2026-09-15: умолчание = проектор стенда (на CPU, см. MmprojDevice); "" — без зрения.
  [string]$Mmproj = "F:\Harness_AI\models\mmproj-F16.gguf",
  [string]$MmprojDevice = "none",
  # Сэмплинг (bench-09). Умолчания дословно повторяют прежние зашитые
  # константы, поэтому базовая рука остаётся сопоставимой с bench-03..08.
  #
  # Типы [string], а не [double], намеренно: PS 5.1 форматирует [double] по
  # текущей культуре, и в локали с запятой "0,9" ушло бы в exe и было бы
  # прочитано как 0. Тот же капкан уже сработал на -Dry (см. ниже). Строка
  # заодно сохраняет "0.90" в точности, а не "0.9".
  # 2026-09-15: умолчания = рабочая рука лончера (решение 13, bench-09:
  # temp 1.0 / top-p 0.95 / top-k 20 / min-p 0). Прежние 0.4/0.90/15/0.02
  # (bench-03..08) — руками, если нужна сопоставимость со старыми замерами.
  # Ручной запуск без параметров = тот же стенд, что поднимает лончер.
  [string]$Temp   = "1.0",
  [string]$TopP   = "0.95",
  [string]$TopK   = "20",
  [string]$MinP   = "0.0",
  # Штрафы. Пустая строка = флаг не передаётся, то есть умолчание сборки
  # (presence 0.0, repeat 1.0 — оба выключены). Рекомендация Qwen для
  # non-thinking просит presence 1.5.
  [string]$PresencePenalty = "",
  [string]$RepeatPenalty   = "",
  # Обычный режим вместо thinking. Шаблон модели проверяет
  # `enable_thinking is undefined or enable_thinking is true`, поэтому
  # выключается явным false в chat-template-kwargs. Рекомендация Qwen для
  # этого режима: temp 0.7, top-p 0.80, top-k 20, min-p 0.0, presence 1.5.
  [switch]$NoThinking,
  # Произвольные дополнительные флаги llama-server — для проб, а не для
  # рабочего запуска. Добавлено при проверке набора флагов Ollama (проба 12):
  # -b/-ub и --spec-draft-backend-sampling у нас не задавались никогда, и
  # проверить их можно только замером. В рабочей команде оставаться не должны:
  # что доказано замером — переносится в явный параметр выше.
  # Строка, а не [string[]]: в режиме -File PowerShell склеивает
  # "-Extra -b,1024,-ub,1024" в ОДИН элемент, и llama-server отвергает его
  # целиком ("invalid argument: -b,1024,-ub,1024"). Разбираем сами по пробелу.
  [string]$Extra = "",
  # Только напечатать командную строку и выйти (сверка конфигурации без запуска).
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

# Без -NoThinking строка обязана совпасть с прежней ДОСЛОВНО, иначе базовая
# рука несопоставима с прошлыми замерами. Пробелов внутри JSON нет: PS 5.1
# и режет внутренние кавычки, и разбивает аргумент по пробелам при передаче
# в нативный exe.
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
  # "auto" из справки -- описание умолчания, а не допустимое значение: сервер
  # отвергает его с "invalid device: auto". Пустая строка = флаг не передаётся,
  # то есть штатная выгрузка проектора на GPU.
  if ($MmprojDevice) { $a += @("--mmproj-device", $MmprojDevice) }
}

# Единственная переменная замера bench-05. Числа передаются как строки: PS 5.1
# форматирует [double] по текущей культуре, и в локали с запятой в качестве
# десятичного разделителя "0,8" ушло бы в exe и было бы прочитано как 0.
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
