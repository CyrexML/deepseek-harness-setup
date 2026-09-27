/**
 * Advisory notice - tell the model when it has been working for a long time
 * without writing anything to disk.
 *
 * WHY THIS EXISTS
 *
 * Measured on session bbfafd8c (2026-09-27, Cooking_APP). One turn, 26 minutes,
 * 32 steps, 50 tool calls: 48 bash, 2 read, and NOT ONE write or edit. The
 * model held the whole rewritten module in its head and put it in the final
 * answer instead - 19 330 characters of reasoning plus 25 900 of text - which
 * ran into the output cap. The turn ended `max-tokens`, the file was cut off
 * mid-way, and nothing reached the disk: 26 minutes for zero change.
 *
 * `AGENTS.md` already says "never print file contents into chat" and "write
 * code straight to disk". Those rules were not in context for that run (the
 * global file had grown past the instruction budget and was dropped whole), but
 * the deeper problem is the one read-budget-notice was written for: asking does
 * not reliably work. A streak of tool calls with nothing written is observable,
 * so it is said out loud in the currency being spent - steps, and the cap the
 * answer is about to hit.
 *
 * WHY IT NEVER BLOCKS
 *
 * Long read-only stretches are legitimate: diagnosis, a review, answering a
 * question about the code. A gate would stall all of them. This only speaks,
 * twice per turn at most.
 */
import { randomUUID } from 'node:crypto'

export const name = 'write-streak-notice'

/** Listeners only; nothing is resolved from the registry. */
export const inject = []

const SOURCE = { kind: 'plugin', plugin: 'write-streak-notice' }

function positiveInteger(value, field, fallback) {
  if (value === undefined) return fallback
  if (!Number.isInteger(value) || value <= 0) {
    throw new TypeError(`write-streak-notice: ${field} must be a positive integer, got ${JSON.stringify(value)}`)
  }
  return value
}

/**
 * Mount the notice.
 *
 * @param ctx - the plugin context.
 * @param config - `warnCalls` / `urgentCalls` are streak lengths in tool calls;
 *   `writeTools` are the tool names that reset the streak; `maxTokens` is the
 *   model's answer cap, quoted in the message.
 */
export function apply(ctx, config = {}) {
  const warnCalls = positiveInteger(config.warnCalls, 'warnCalls', 12)
  const urgentCalls = positiveInteger(config.urgentCalls, 'urgentCalls', 24)
  if (urgentCalls <= warnCalls) {
    throw new RangeError(`write-streak-notice: urgentCalls (${urgentCalls}) must exceed warnCalls (${warnCalls})`)
  }
  const writeTools = new Set(config.writeTools ?? ['write', 'edit'])
  const maxTokens = positiveInteger(config.maxTokens, 'maxTokens', 12288)

  /** agent -> { calls, level } for the current turn */
  const streak = new WeakMap()
  /** session id -> the agents seen on it, so a new turn can reset them */
  const bySession = new Map()

  const stateOf = (agent) => {
    let s = streak.get(agent)
    if (s === undefined) {
      s = { calls: 0, level: 0 }
      streak.set(agent, s)
    }
    return s
  }

  // A new turn is new work: the streak is about this turn, not the session.
  // A compaction deliberately does NOT reset it - context was just freed while
  // the unwritten file is still only in the model's head, which is the moment
  // the warning matters most.
  ctx.on('session/event', (session, event) => {
    if (event.type !== 'turn/start') return
    for (const agent of bySession.get(session.id) ?? []) streak.delete(agent)
  })

  const message = (text, summary) => Object.freeze({
    id: randomUUID(),
    role: 'user',
    content: [{ type: 'text', text }],
    source: { ...SOURCE, form: 'notice', summary },
  })

  function notice(exec) {
    if (!exec.agent) return undefined

    const session = exec.agent.session
    if (session !== undefined) {
      let agents = bySession.get(session.id)
      if (agents === undefined) { agents = new Set(); bySession.set(session.id, agents) }
      agents.add(exec.agent)
    }

    const s = stateOf(exec.agent)

    if (writeTools.has(exec.name)) {
      s.calls = 0
      s.level = 0
      return undefined
    }

    s.calls += 1
    const level = s.calls >= urgentCalls ? 2 : s.calls >= warnCalls ? 1 : 0
    if (level <= s.level) return undefined
    s.level = level

    const tail = level === 2
      ? 'If you are holding a finished file, write it NOW, before anything else.'
      : 'If part of the result is already decided, write that part now and carry on.'

    return message(
      `${s.calls} tool calls in this turn and nothing written yet. The answer is capped at ${maxTokens} tokens: a file composed in the reply instead of being written runs into that cap, the turn ends on max-tokens, and the work is lost with nothing on disk. ${tail}`,
      `no write in ${s.calls} calls`,
    )
  }

  // Observe and enrich, never veto.
  ctx.on('tools/post-execute', async (exec, result, next) => {
    let note
    try {
      note = notice(exec)
    } catch (error) {
      ctx.logger?.warn?.(`write-streak-notice: ${error}`)
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
