/**
 * Advisory: ask ONCE per session whether this project wants a DECISIONS.md,
 * at the moment the work starts to look like it will outlive the session.
 * Never creates the file, never blocks anything.
 *
 * WHY THIS EXISTS
 *
 * The handoff file is what lets a cold session skip reading the code, and its
 * map is the single cheapest thing in the whole setup (measured 2026-09-10:
 * nine map lines, ~150 tokens, standing in for 17 762 tokens of exploratory
 * reading). But a new project starts without one, and nothing creates it.
 *
 * A rule in `AGENTS.md` can say "create it". The trouble is the rule is read at
 * step 1, when the project is one empty file and the file would be pointless,
 * and by step 30 - when it would pay - the rule is far up the context. That is
 * the same failure mode as the size and read-budget rules.
 *
 * WHY IT ASKS INSTEAD OF DECIDING
 *
 * Most one-off tasks genuinely should NOT have this file: a throwaway script,
 * a single fix, a question answered in one edit. Writing a handoff file for
 * those costs tokens and leaves a stale artefact behind. Whether the work will
 * be picked up again is a judgement only the agent (and the user) can make, so
 * the note states the situation and explicitly says to ignore it for a one-off.
 *
 * THE TRIGGER
 *
 * Two signals, either of which means "this is no longer a one-off":
 *
 *  - `minFiles` distinct files written or edited in the project this session
 *    (default 3 - one file is a script, two is a script and its test, three is
 *    a structure someone will have to navigate);
 *  - a compaction has already happened AND `minFilesAfterCompaction` files were
 *    touched (default 2). A compaction means the session has already outrun one
 *    context window, so a successor session is likely and will start blind.
 *
 * Fires at most once per session, and never when the file already exists - so
 * the moment the agent creates it, the plugin goes quiet for good.
 *
 * @module decisions-file-notice
 */

import { existsSync } from 'node:fs'
import { sep } from 'node:path'
import { randomUUID } from 'node:crypto'

export const name = 'decisions-file-notice'

/** Listeners only; nothing is resolved from the registry. */
export const inject = []

const SOURCE = { kind: 'plugin', plugin: 'decisions-file-notice' }

const PATH_FIELDS = ['file_path', 'path', 'filePath']

function positiveInteger(value, field, fallback) {
  if (value === undefined) return fallback
  if (!Number.isInteger(value) || value <= 0) {
    throw new TypeError(`decisions-file-notice: ${field} must be a positive integer, got ${JSON.stringify(value)}`)
  }
  return value
}

/**
 * Mount the notice.
 *
 * @param ctx - the plugin context.
 * @param config - `fileName` (default `DECISIONS.md`), `minFiles`,
 *   `minFilesAfterCompaction`, and `tools` (the tool names that count as
 *   "touching a file").
 */
export function apply(ctx, config = {}) {
  const fileName = typeof config.fileName === 'string' && config.fileName.length > 0
    ? config.fileName
    : 'DECISIONS.md'
  const minFiles = positiveInteger(config.minFiles, 'minFiles', 3)
  const minAfterCompaction = positiveInteger(config.minFilesAfterCompaction, 'minFilesAfterCompaction', 2)
  const tools = new Set(config.tools ?? ['write', 'edit'])

  /** agent -> { touched: Set<path>, asked: boolean } */
  const state = new WeakMap()
  /** session id -> whether a compaction has happened on it */
  const compacted = new Set()

  ctx.on('session/event', (session, event) => {
    if (event.type === 'compaction/end') compacted.add(session.id)
  })

  const pathOf = (exec) => {
    let args = exec.arguments
    if (typeof args === 'string') {
      try { args = JSON.parse(args) } catch { return undefined }
    }
    if (args === null || typeof args !== 'object') return undefined
    for (const field of PATH_FIELDS) {
      const value = args[field]
      if (typeof value === 'string' && value.length > 0) return value
    }
    return undefined
  }

  function notice(exec) {
    if (!exec.agent) return undefined
    if (!tools.has(exec.name)) return undefined
    const path = pathOf(exec)
    if (path === undefined) return undefined

    // The project root is the session's own working directory: the same place
    // the handoff file is read from at the start of the next session.
    const session = exec.agent.session
    const root = session?.header?.cwd
    if (typeof root !== 'string' || root.length === 0) return undefined
    if (!path.startsWith(root.endsWith(sep) ? root : root + sep)) return undefined

    let s = state.get(exec.agent)
    if (s === undefined) {
      s = { touched: new Set(), asked: false }
      state.set(exec.agent, s)
    }
    if (s.asked) return undefined
    s.touched.add(path)

    const marker = (root.endsWith(sep) ? root : root + sep) + fileName
    // Already answered - by the agent creating it, or by the project having had
    // one all along. Nothing to ask, now or later this session.
    if (existsSync(marker)) {
      s.asked = true
      return undefined
    }

    const threshold = compacted.has(session.id) ? minAfterCompaction : minFiles
    if (s.touched.size < threshold) return undefined
    s.asked = true

    return Object.freeze({
      id: randomUUID(),
      role: 'user',
      content: [{
        type: 'text',
        text: `This project has no ${fileName} and you have written or edited ${s.touched.size} files in it. `
          + `If the work will be picked up again - by a later session or after a compaction - create it now, in the handoff shape from your working rules: `
          + `a title line, "## Where the code is" with one row per file listing the symbols it owns, "## Decisions", "## State". `
          + `The map is the part that pays: it is what lets the next session open one file instead of reading the tree. `
          + `If this is a one-off that nobody will continue, ignore this - a handoff file for throwaway work is just a stale artefact.`,
      }],
      source: { ...SOURCE, form: 'notice', summary: `no ${fileName} (${s.touched.size} files)` },
    })
  }

  // Observe and enrich, never veto.
  ctx.on('tools/post-execute', async (exec, _result, next) => {
    let note
    try {
      note = notice(exec)
    } catch (error) {
      ctx.logger?.warn?.(`decisions-file-notice: ${error}`)
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
