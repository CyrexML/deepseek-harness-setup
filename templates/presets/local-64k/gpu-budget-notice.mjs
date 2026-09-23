/**
 * GPU budget notice — stop the first GPU training launch that cannot possibly
 * succeed, and say why, instead of letting it die in `CUDA out of memory`.
 *
 * WHY THIS EXISTS
 *
 * On this stand the local model holds the card: `30-tune.ps1` sizes the context
 * window so that 150–500 MiB of VRAM stay free. That is deliberate and it is
 * also invisible to the model — nothing in a session says how much video memory
 * is left, so a request like "train a small CNN on this dataset" produces
 * `python train.py`, several minutes of dataset loading, and then an OOM
 * traceback that costs more context than the whole task.
 *
 * The model cannot reason about a number it was never given. This plugin gives
 * it the number at the only moment it matters: the launch.
 *
 * WHY IT DENIES INSTEAD OF WARNING
 *
 * The sibling advisories (`file-size-notice`, `read-budget-notice`) never veto,
 * because they describe a cost that is worth paying sometimes. This one is
 * different: with 173 MiB free a CUDA training run has NO outcome except the
 * OOM. Letting it proceed spends minutes and a large traceback to learn what
 * `nvidia-smi` already knows. So the first such command is denied with the
 * measurement and the three ways out; the model relays them to the user.
 *
 * WHY ONLY THE FIRST ONE
 *
 * After the note the situation may legitimately change — the user stops the
 * model server, re-tunes with `-ReserveMb`, or decides to try anyway with a
 * tiny batch. A plugin that kept denying would override a decision that is not
 * its to make, so it denies once per agent and then stays out of the way.
 *
 * WHAT COUNTS AS A GPU LAUNCH
 *
 * Training/inference launchers only (`torchrun`, `accelerate launch`, a python
 * run whose command mentions training or a CUDA device, `nvidia-smi` excluded).
 * A command that explicitly asks for the CPU — `CUDA_VISIBLE_DEVICES=`,
 * `--device cpu`, `--cpu` — is never touched: that is exactly the fallback this
 * note recommends, and denying it would be absurd.
 */
import { execFileSync } from 'node:child_process'

export const name = 'gpu-budget-notice'

/** Listeners only; nothing is resolved from the registry. */
export const inject = []

/** Launchers that put work on the GPU. */
const GPU_LAUNCH = /\b(torchrun|accelerate\s+launch|deepspeed)\b|\bpython3?\b[^\n]*\b(train|finetune|fine_tune|sft|pretrain)\w*\.py\b|\b(trainer\.train|model\.fit)\s*\(|\bdiffusers?\b[^\n]*\b(pipeline|generate)\b/i

/** An explicit request for the CPU is the recommended fallback, not a mistake. */
const CPU_INTENT = /CUDA_VISIBLE_DEVICES\s*=\s*(''|""|\s|$)|--device[= ]cpu|--cpu\b|--no-cuda\b/i

function positiveInteger(value, field, fallback) {
  if (value === undefined) return fallback
  if (!Number.isInteger(value) || value <= 0) {
    throw new TypeError(`gpu-budget-notice: ${field} must be a positive integer, got ${JSON.stringify(value)}`)
  }
  return value
}

/**
 * Free and total VRAM in MiB, or undefined when the card cannot be measured
 * (no NVIDIA driver, nvidia-smi missing, WSL without GPU passthrough). Every
 * failure means "say nothing": a machine we cannot measure gets no advice.
 * Cached briefly — a launch is often preceded by several probing commands.
 */
function readVram(cache, ttlMs) {
  const now = Date.now()
  if (cache.at !== undefined && now - cache.at < ttlMs) return cache.value
  let value
  try {
    const out = execFileSync('nvidia-smi', ['--query-gpu=memory.free,memory.total', '--format=csv,noheader,nounits'], {
      encoding: 'utf8', timeout: 4000, stdio: ['ignore', 'pipe', 'ignore'],
    })
    const [free, total] = out.split('\n')[0].split(',').map(part => Number.parseInt(part.trim(), 10))
    value = Number.isFinite(free) && Number.isFinite(total) ? { free, total } : undefined
  } catch {
    value = undefined
  }
  cache.at = now
  cache.value = value
  return value
}

export function apply(ctx, config = {}) {
  const minFreeMb = positiveInteger(config.minFreeMb, 'minFreeMb', 2048)
  const ttlMs = positiveInteger(config.cacheMs, 'cacheMs', 15000)
  const cache = {}
  const told = new Set()

  function command(exec) {
    const args = exec?.args ?? exec?.arguments ?? exec?.input
    const value = args?.command ?? args?.cmd
    return typeof value === 'string' ? value : undefined
  }

  function reason(exec) {
    if ((exec?.tool?.name ?? exec?.name ?? exec?.toolName) !== 'bash') return undefined
    const cmd = command(exec)
    if (cmd === undefined || !GPU_LAUNCH.test(cmd) || CPU_INTENT.test(cmd)) return undefined
    const agent = exec.agent ?? 'main'
    if (told.has(agent)) return undefined

    const vram = readVram(cache, ttlMs)
    if (vram === undefined || vram.free >= minFreeMb) return undefined
    told.add(agent)

    const usedMb = vram.total - vram.free
    return [
      `Not started: this machine has ${vram.free} MiB of VRAM free out of ${vram.total} MiB.`,
      `The local model server holds the other ${usedMb} MiB for as long as the stand runs, so a CUDA run here ends in "CUDA out of memory" and nothing else.`,
      '',
      'Do NOT retry the command and do NOT work around it silently. Tell the user what has to happen first, and give the exact steps:',
      '',
      `1. Keep VRAM free for their own work and shrink the model's context window to match:`,
      '   powershell -ExecutionPolicy Bypass -File windows\\30-tune.ps1 -ReserveMb 6000',
      '   (6000 = MiB left for training; a smaller model, e.g. Qwen3.5 9B, leaves more room.)',
      '2. Or free the card completely for the duration of the run — stop the model server',
      '   (run\\stop-server.ps1). The agent has no model while it is stopped, so this suits',
      '   a run that is started and then watched, not an interactive session.',
      '3. Or run on the CPU for a small experiment: CUDA_VISIBLE_DEVICES= python train.py',
      '   (correct but slow — reasonable to check that the code runs at all).',
      '',
      'Meanwhile the work that does not need the GPU is worth doing now: write the training script, the data pipeline and the config, and say plainly that the run itself is waiting on video memory.',
    ].join('\n')
  }

  // Delegate first so an existing veto keeps its own wording; only an otherwise
  // allowed launch is turned into the note.
  ctx.on('tools/pre-execute', async (exec, next) => {
    let text
    try {
      text = reason(exec)
    } catch (error) {
      ctx.logger?.warn?.(`gpu-budget-notice: ${error}`)
      text = undefined
    }
    const downstream = await next()
    if (text === undefined || downstream.kind !== 'allow') return downstream
    return { kind: 'deny', reason: text }
  })
}
