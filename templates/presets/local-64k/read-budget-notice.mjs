/**
 * Advisory read-budget notice - tell the model how much of the working budget
 * it has spent READING this compaction cycle, at the moment it crosses a
 * threshold. Never vetoes, never rewrites, never blocks a read.
 *
 * WHY THIS EXISTS
 *
 * Splitting a 1039-line index.html into nine modules saved nothing, because the
 * agent read the modules anyway. Measured on session c47f7d3f (2026-09-10):
 *
 *   9 steps, 7 reads - EVERY ONE whole-file, one grep in the whole run
 *   DECISIONS.md 3485 + index.html 3996 + main 4390 + render 2125
 *     + state 1675 + canvas 1044 + steps 1047  =  17 762 tokens
 *   97% of the 18 141-token cycle. The old single file cost 18 423.
 *   Net saving from the whole split: 661 tokens, 3.6%.
 *
 * The split made narrow reading POSSIBLE; it did not make it HAPPEN. The
 * `AGENTS.md` rules "read narrowly" and "do not re-read what you just wrote"
 * ask for the behaviour, and asking demonstrably does not work: they were in
 * force for that entire run.
 *
 * So this is the same shape as `file-size-notice` - state the cost in the
 * currency the model is actually spending, at the moment it spends it.
 *
 * WHY IT NEVER BLOCKS
 *
 * A read the model needs is worth its price; only the model knows which those
 * are. A gate would stall real work, and `tools/post-execute` runs after the
 * read anyway - blocking would reject a result already paid for. So the plugin
 * delegates to `next()` unconditionally and only folds a note onto the result.
 *
 * TWO NOTICES
 *
 *  1. BUDGET - cumulative reads since the last compaction crossed a share of
 *     the cycle. Fires once per level (warn, then urgent) per cycle.
 *  2. RE-READ - a file read whole that was already read whole this cycle. This
 *     is pure waste and is always worth one line.
 *
 * The counter resets on `compaction/end`: after a compaction the retained tail
 * is what it is, and the budget starts again.
 *
 * CALIBRATION - shared with file-size-notice, re-measure together.
 *   3.08 bytes per token; cycle 18 141 tokens (threshold 45 875 minus prefix
 *   8 483 + tail 13 107 + summary 6 144).
 *
 * @module read-budget-notice
 */

import { randomUUID } from 'node:crypto'

export const name = 'read-budget-notice'

/** Listeners only; nothing is resolved from the registry. */
export const inject = []

const SOURCE = { kind: 'plugin', plugin: 'read-budget-notice' }

const PATH_FIELDS = ['file_path', 'path', 'filePath']

function positiveInteger(value, field, fallback) {
  if (value === undefined) return fallback
  if (!Number.isInteger(value) || value <= 0) {
    throw new TypeError(`read-budget-notice: ${field} must be a positive integer, got ${JSON.stringify(value)}`)
  }
  return value
}

function positiveNumber(value, field, fallback) {
  if (value === undefined) return fallback
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) {
    throw new TypeError(`read-budget-notice: ${field} must be a positive number, got ${JSON.stringify(value)}`)
  }
  return value
}

/**
 * Mount the notice.
 *
 * @param ctx - the plugin context.
 * @param config - `warnPercent` / `urgentPercent` are shares of `cycleTokens`;
 *   `tools` are the tool names counted; `bytesPerToken` and `cycleTokens` are
 *   the calibration constants in the header.
 */
export function apply(ctx, config = {}) {
  const warnPercent = positiveInteger(config.warnPercent, 'warnPercent', 45)
  const urgentPercent = positiveInteger(config.urgentPercent, 'urgentPercent', 75)
  if (urgentPercent <= warnPercent) {
    throw new RangeError(`read-budget-notice: urgentPercent (${urgentPercent}) must exceed warnPercent (${warnPercent})`)
  }
  const bytesPerToken = positiveNumber(config.bytesPerToken, 'bytesPerToken', 3.08)
  const cycleTokens = positiveInteger(config.cycleTokens, 'cycleTokens', 18141)
  const tools = new Set(config.tools ?? ['read'])

  /** agent -> { tokens, level, files: Map(path -> tokens) } for the current cycle */
  const spent = new WeakMap()
  /** session id -> the agents seen on it, so a compaction can reset them */
  const bySession = new Map()

  const stateOf = (agent) => {
    let s = spent.get(agent)
    if (s === undefined) {
      s = { tokens: 0, level: 0, files: new Map() }
      spent.set(agent, s)
    }
    return s
  }

  // A compaction rewrites the surface: the retained tail is whatever it is and
  // the budget starts over. Without this the counter would only ever climb and
  // the notice would fire once, early, then never again.
  ctx.on('session/event', (session, event) => {
    if (event.type !== 'compaction/end') return
    for (const agent of bySession.get(session.id) ?? []) spent.delete(agent)
  })

  const pathOf = (exec) => {
    let args = exec.arguments
    if (typeof args === 'string') {
      try { args = JSON.parse(args) } catch { return undefined }
    }
    if (args === null || typeof args !== 'object') return undefined
    for (const field of PATH_FIELDS) {
      const value = args[field]
      if (typeof value === 'string' && value.length > 0) return { path: value, ranged: args.offset !== undefined || args.limit !== undefined }
    }
    return undefined
  }

  /**
   * Size of what came back, in tokens. Measured from the RESULT rather than the
   * file, so a ranged read is charged for the range it actually returned.
   * JSON escaping inflates newlines by one byte each, a few percent on code -
   * an overcount in the safe direction for a budget warning.
   */
  const resultTokens = (result) => {
    try {
      const text = typeof result === 'string' ? result : JSON.stringify(result ?? '')
      return Math.round(Buffer.byteLength(text, 'utf8') / bytesPerToken)
    } catch {
      return 0
    }
  }

  const message = (text, summary) => Object.freeze({
    id: randomUUID(),
    role: 'user',
    content: [{ type: 'text', text }],
    source: { ...SOURCE, form: 'notice', summary },
  })

  function notice(exec, result) {
    if (!exec.agent) return undefined
    if (!tools.has(exec.name)) return undefined
    const target = pathOf(exec)
    if (target === undefined) return undefined

    const session = exec.agent.session
    if (session !== undefined) {
      let agents = bySession.get(session.id)
      if (agents === undefined) { agents = new Set(); bySession.set(session.id, agents) }
      agents.add(exec.agent)
    }

    const s = stateOf(exec.agent)
    const tokens = resultTokens(result)

    // A whole-file read of something already read whole this cycle is pure
    // waste - the content is still in the conversation above.
    const previous = s.files.get(target.path)
    const repeat = !target.ranged && previous !== undefined && previous.whole

    s.tokens += tokens
    s.files.set(target.path, { whole: !target.ranged, tokens: (previous?.tokens ?? 0) + tokens })

    if (repeat) {
      return message(
        `You already read ${target.path} in full this cycle (~${previous.tokens} tokens). It is still above in the conversation - scroll back instead of paying for it twice. If you need one region again, read it with grep -n or a line range.`,
        `re-read ${target.path.split('/').pop()}`,
      )
    }

    const percent = Math.round((s.tokens / cycleTokens) * 100)
    const level = percent >= urgentPercent ? 2 : percent >= warnPercent ? 1 : 0
    if (level === 0 || level <= s.level) return undefined
    s.level = level

    const biggest = [...s.files.entries()]
      .sort((a, b) => b[1].tokens - a[1].tokens)
      .slice(0, 3)
      .map(([p, v]) => `${p.split('/').pop()} ${v.tokens}`)
      .join(', ')

    const tail = level === 2
      ? 'Very little of this cycle is left for actual work. Stop opening files: locate with grep -n and read line ranges only.'
      : 'Before the next read, check whether grep -n or a line range would answer the question.'

    return message(
      `Reading has cost ~${s.tokens} tokens this compaction cycle, ${percent}% of the ~${cycleTokens} available between compactions. Largest: ${biggest}. ${tail}`,
      `read budget ${percent}%`,
    )
  }

  // Observe and enrich, never veto.
  ctx.on('tools/post-execute', async (exec, result, next) => {
    let note
    try {
      note = notice(exec, result)
    } catch (error) {
      ctx.logger?.warn?.(`read-budget-notice: ${error}`)
      note = undefined
    }
    const downstream = await next()
    if (note === undefined) return downstream
    const contexts = [note, ...(downstream.additionalContexts ?? [])]
    if (downstream.kind === 'block') {
      return { kind: 'block', feedback: downstream.feedback, additionalContexts: contexts }
    }
    return { ...downstream, additionalContexts: contexts }
  })
}
