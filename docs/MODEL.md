# The model: what to download, where to put it, how to tune it

**[Русская версия](MODEL.ru.md)**

Short version: **you do not have to choose anything by hand.** Run the wizard

```powershell
powershell -ExecutionPolicy Bypass -File windows\20-model.ps1
```

It looks at your GPU, suggests a model that fits, downloads it into the right folder and
writes the settings for you. Everything below is the same thing in words, for when you
want to do it manually or just understand what happens.

---

## 1. Where the files live

Everything sits in one folder — the one named `windowsRoot` in `config.json`:

```
F:\Harness_AI\
  models\
    <model>.gguf           ← the model itself (the main file, 8–30 GB)
    mmproj-F16.gguf        ← the model's "eyes": image understanding (optional)
    chat-agent.jinja       ← chat template (written by the installer, leave it alone)
  llama.cpp\               ← the engine, installed for you
  run\                     ← logs and launch scripts
```

The installer creates `models`. The model file is simply placed there — nothing to
unpack or rename. Any drive works (C:, D:, F:) as long as the path matches
`windowsRoot` in `config.json`.

## 2. Which model to take

It is decided by the amount of video memory (VRAM), not by how fast the card is:

```powershell
nvidia-smi --query-gpu=name,memory.total --format=csv
```

| VRAM | Model | File | Context window |
|---|---|---|---|
| 10 GB | Qwen3.5 9B (MTP) | `Qwen3.5-9B-MTP-UD-Q4_K_XL.gguf` (6.1 GB) | 32k |
| 12 GB | Qwen3.5 9B (MTP) | `Qwen3.5-9B-MTP-UD-Q5_K_XL.gguf` (6.9 GB) | 48k |
| 14 GB | Qwen3.5 9B (MTP) | `Qwen3.5-9B-MTP-UD-Q6_K_XL.gguf` (9.0 GB) | 64k |
| 16 GB | Qwen3.8 27B | `Qwen3.8-27B-UD-Q3_K_XL.gguf` (13 GB) | 64k ← what this repo is tuned for |
| 24 GB | Qwen3.8 27B | `Qwen3.8-27B-UD-Q4_K_XL.gguf` (17 GB) | 64k |
| 32 GB+ | Qwen3.8 27B | `Qwen3.8-27B-Q5_K_M.gguf` (21 GB) | 128k |

Both lines support multi-token prediction (MTP), which is what the stand's generation
speed relies on — that is why the catalog only lists those builds.

The rule of thumb: **the model file should take about 80% of your VRAM.** The rest goes
to the context (the conversation history) and working buffers. A model that does not fit
spills onto the CPU, and speed drops 5–20 times.

Quants (`Q3`, `Q4`, `Q5`) are how hard the weights are compressed: the smaller the
number, the smaller the file and the worse the answers. The `UD-` prefix from Unsloth
means a *dynamic* quant — important layers are compressed less, so UD-Q3 is noticeably
better than a plain Q3.

## 3. How to download it

**Option 1 — the wizard (recommended).** `windows\20-model.ps1` downloads the file with
resume support and puts it where it belongs.

**Option 2 — by hand.** Open the model page on Hugging Face, download the `.gguf` and
drop it into `F:\Harness_AI\models\`:

- Qwen3.8 27B: <https://huggingface.co/unsloth/Qwen3.8-27B-GGUF>
- Qwen3.5 9B (MTP): <https://huggingface.co/unsloth/Qwen3.5-9B-MTP-GGUF>

Take exactly the filename from the table above. Files named `...-00001-of-00002.gguf`
are a model split into parts — download **all** parts into the same folder and the
engine will stitch them together.

**Option 3 — from a console** (faster, resumable):

```powershell
pip install -U "huggingface_hub[cli]"
hf download unsloth/Qwen3.8-27B-GGUF Qwen3.8-27B-UD-Q3_K_XL.gguf --local-dir F:\Harness_AI\models
```

Image understanding is optional: take `mmproj-F16.gguf` from the same repository.
Without it the stand works fine, it just cannot see attached images.

## 4. Tuning after the download

This used to be the part where everything had to be dialled in by hand. Now:

```powershell
powershell -ExecutionPolicy Bypass -File windows\30-tune.ps1
```

The wizard:

1. reads your VRAM and the size of the model file;
2. computes the context window (`ctx`) that fits with a `q4_0`-compressed KV cache;
3. enables speculative decoding (MTP) if the model supports it;
4. writes everything into `config.json` and into `run\start-server.ps1`;
5. starts the server and runs a measurement, printing prefill and generation speed;
6. creates the agent preset (`local-<ctx>`) so the UI knows the window and the model.

Nothing needs editing afterwards. If you want to, every value lives in `config.json`
under `server`, and the wizard can be re-run at any time.

### What is being set, and why

| Flag | What it is | Why this value |
|---|---|---|
| `-ngl 99` | how many layers go to the GPU | all of them: anything else costs several times the speed |
| `--fit off` | do not auto-shrink the model | we do the sizing, not the engine |
| `-c <ctx>` | context window in tokens | a bigger window costs VRAM for the cache |
| `--cache-type-k/v q4_0` | conversation cache compression | exactly twice the window for the same VRAM; `q4_0` specifically, because the fast FlashAttention kernel supports it |
| `--spec-type draft-mtp` | predicts several tokens ahead | +30–60% generation speed on MTP-capable models |
| `--reasoning-budget 5000` | cap on "thinking" per step | without a cap the model can think indefinitely |
| `--chat-template-file` | our own chat template | strips repeated reasoning from the history; without it the context grows several times faster |

## 5. Checking that it is healthy

```powershell
powershell -ExecutionPolicy Bypass -File windows\30-tune.ps1 -CheckOnly
```

Prints the model, the window, used VRAM and the measured speeds. On an RTX 5080 (27B UD-Q3_K_XL, 64k window): prefill ~1970 tok/s, generation ~95 tok/s,
150–500 MiB VRAM free.

If generation is well under 20 tok/s, the model almost certainly did not fit into VRAM:
take a smaller quant or reduce `ctx`.

## 6. Questions people ask

**"Can I use something other than Qwen?"** Yes, any GGUF that llama.cpp understands.
The chat template (`chat-agent.jinja`) is written for Qwen3 though; for another model
remove `chatTemplateFile` from `config.json` and the template baked into the model file
will be used instead. Speculative decoding (MTP) is not available on every model — the
wizard checks and turns it off when it is missing.

**"The model is already downloaded elsewhere, should I copy it?"** No — put the path
into `config.json` → `model.path`, the wizard accepts any location.

**"How much disk does this need?"** Model 13 GB + engine ~2 GB + harness ~3 GB. Budget
40 GB.

**"Do I need a permanent internet connection?"** No. Only once, during installation.
After that everything runs locally; the internet is only needed for phone access
through the tunnel.
