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
 * WHAT IT ASKS FOR INSTEAD
 *
 * "You cannot run this" is only half an answer. The half that matters is the
 * work that does NOT need the card — the script itself, the data pipeline, the
 * config, a CPU smoke run on a tiny subset — plus a written hand-off the user
 * can execute alone later: exact commands to free the card, to install the
 * right CUDA wheel, to start the run and to put the stand back. So the note
 * prescribes that sequence and names the file to leave behind, and it carries
 * the environment facts (python, torch, driver, VRAM) measured here, so the
 * model does not spend turns rediscovering them.
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

/**
 * One-line facts about the machine that a training hand-off needs: interpreter,
 * whether torch is already there, driver and its CUDA. Each probe is optional —
 * anything that fails is simply left out, never guessed.
 */
function environment(cache) {
  if (cache.env !== undefined) return cache.env
  const run = (file, args, timeout = 6000) => {
    try {
      return execFileSync(file, args, { encoding: 'utf8', timeout, stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    } catch {
      return undefined
    }
  }
  const python = run('python3', ['-V'])
  const torch = python === undefined
    ? undefined
    : run('python3', ['-c', 'import torch;print(torch.__version__, torch.version.cuda or "cpu-only")'], 20000)
  const driver = run('nvidia-smi', ['--query-gpu=driver_version', '--format=csv,noheader'])
  const cuda = (run('nvidia-smi', []) ?? '').match(/CUDA Version:\s*([0-9.]+)/)?.[1]
  cache.env = { python, torch, driver, cuda }
  return cache.env
}

export function apply(ctx, config = {}) {
  const minFreeMb = positiveInteger(config.minFreeMb, 'minFreeMb', 2048)
  const ttlMs = positiveInteger(config.cacheMs, 'cacheMs', 15000)
  // Файл, который остаётся пользователю: по нему запуск повторяется без агента.
  const handoffFile = typeof config.handoffFile === 'string' && config.handoffFile.length > 0
    ? config.handoffFile
    : 'RUN-TRAINING.md'
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
    const env = environment(cache)
    const facts = [
      env.python === undefined ? undefined : `interpreter: ${env.python}`,
      env.torch === undefined ? 'torch: not installed in the default interpreter' : `torch: ${env.torch}`,
      env.driver === undefined ? undefined : `driver: ${env.driver}${env.cuda === undefined ? '' : `, supports CUDA up to ${env.cuda}`}`,
    ].filter(Boolean).join('; ')

    return [
      `Not started: this machine has ${vram.free} MiB of VRAM free out of ${vram.total} MiB.`,
      `The local model server holds the other ${usedMb} MiB for as long as the stand runs, so a CUDA run here ends in "CUDA out of memory" and nothing else.`,
      'On top of that your shell has no GPU device: the sandbox gives it a bare /dev, which is why nvidia-smi answers "GPU access blocked by the operating system" there. The card is reachable only from the user\'s own terminal.',
      facts.length === 0 ? undefined : `Measured on this machine — ${facts}.`,
      '',
      'Do NOT retry this command and do NOT quietly switch the code to the CPU. Do the part that does not need the card, then hand the run over to the user:',
      '',
      '1. Finish the code. The script, the data pipeline and the config should be ready to start — this is the work the missing VRAM does not block.',
      `2. Prove it runs, on the CPU, on a deliberately tiny subset (a few dozen samples, one short epoch): \`CUDA_VISIBLE_DEVICES= python3 <script> …\`. Commands that ask for the CPU are never blocked here. A CPU pass that completes means the remaining risk is memory, not code. Run the exact command you will put in the instruction, only smaller — a mode or flag you never executed is one you do not know works.`,
      `3. Write ${handoffFile} in the workspace — the instruction the user follows alone, in copy-paste form, with THIS machine's numbers:`,
      '   - freeing the card: either `powershell -ExecutionPolicy Bypass -File windows\\30-tune.ps1 -ReserveMb <MiB>` (the model keeps working with a smaller context window) or `run\\stop-server.ps1` (whole card free, the agent has no model until it is started again);',
      '   - the environment: venv plus the torch wheel matching the driver above, or the exact `pip install` line if torch is already there;',
      '   - the start command with the batch size and any flags the chosen VRAM budget allows, and what to expect in the output;',
      '   - watching it: `nvidia-smi -l 5` in a second window, and what an out-of-memory failure looks like if the budget was set too high;',
      '   - putting the stand back afterwards: the desktop shortcut Harness AI, or `windows\\30-tune.ps1` run again with NO -ReserveMb flag (never -ReserveMb set to the whole card — that would leave the model nothing).',
      '4. Reply with what is ready, what is waiting on video memory, and the path to the file. Do not ask the user to choose between the options before the file exists — describe both in it.',
    ].filter(part => part !== undefined).join('\n')
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
