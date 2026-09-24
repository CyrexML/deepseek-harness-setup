/**
 * compaction-basic for this stand: (1) summarize without the tool catalog,
 * (2) threshold by llama-server usage rather than by the meter's estimate,
 * (3) summaries without reasoning blocks in the replay (see summarize()).
 *
 * (1) Measured over session logs: 23 of 36 compactions in one session and 33 of
 * 73 in another ended with "summarization produced no text summary content".
 * summarizer.ts replays the conversation TOGETHER with the tool schemas (for the
 * prefix cache) and asks the model in prose not to call tools. In the middle of a
 * tool loop the model answers with a tool call, there is no text, the compactor
 * throws, the threshold stays crossed and the attempt repeats on every following
 * step while the context keeps growing. The compactor schema has no knob for
 * this, but `summarize()` is declared the subclass's only hook, so it is called
 * here without `tools`: with no catalog a tool call is physically impossible.
 * The cost: the Qwen template's system message starts with the tools block, so
 * the prefix cache does not match for the summary request - a full prefill of
 * about 40k tokens.
 *
 * (2) With the stand's chat template the reasoning of past steps is not replayed,
 * and server usage became noticeably SMALLER than the meter's estimate
 * (token-meter counts reasoning blocks as chars/4). The meter only takes usage
 * when usage >= estimate, otherwise the estimate - which produced compactions at
 * a real 26237 and 23901 tokens against a 45875 threshold. So before the normal
 * check the real context is computed here: the usage of the last call
 * (input + cacheRead + output) plus an estimate of what landed in the surface
 * after it (tool results, insertions). Below the threshold no compaction starts.
 * Right after a compaction, while there is no new model answer, usage is stale
 * and the normal logic decides. The context-overflow trigger is never intercepted.
 *
 * Imported by absolute path: the preset lives under ~/.dsh and an upward
 * node_modules search never reaches the harness packages. The path matches what
 * the host itself loads, so there is a single module instance.
 */
import Base from '@HARNESS_DIR@/packages/compaction/compaction-basic/lib/index.js'

const CHARS_PER_TOKEN = 3.5

function blocksChars(content) {
  if (!Array.isArray(content)) return typeof content === 'string' ? content.length : 0
  let n = 0
  for (const b of content) {
    if (!b || typeof b !== 'object') continue
    if (typeof b.text === 'string') n += b.text.length
    else if (b.type === 'tool-result') n += blocksChars(b.content)
    else n += JSON.stringify(b).length
  }
  return n
}

/**
 * The real context from the usage of the last model answer, or undefined when a
 * compaction happened after it (usage is stale) or there is no usage at all.
 */
export function usageAnchoredTokens(session) {
  let delta = 0
  for (let seq = session.seq - 1; seq >= 0; seq -= 1) {
    const e = session.eventAt(seq)
    if (e === undefined) continue
    switch (e.type) {
      case 'compaction/summary':
      case 'compaction/prune':
        return undefined
      case 'tool/result':
        delta += blocksChars(e.data.message?.content) / CHARS_PER_TOKEN + 8
        break
      case 'user/message':
        delta += blocksChars(e.data.content) / CHARS_PER_TOKEN + 8
        break
      case 'assistant/message': {
        const u = e.data.usage
        if (u === undefined) return undefined
        // The stand's chat template does not replay the reasoning of the last
        // answer either, so its reasoning tokens are subtracted from
        // outputTokens (from stream chunks, or from characters without them).
        let reasoning = 0
        const stream = e.data.stream
        if (Array.isArray(stream)) {
          for (const ch of stream) if (ch.type === 'reasoning-chunks' && Array.isArray(ch.texts)) reasoning += ch.texts.length
        } else {
          for (const b of e.data.message?.content ?? []) if (b.type === 'reasoning') reasoning += (b.text?.length ?? 0) / CHARS_PER_TOKEN
        }
        return u.inputTokens + (u.cacheReadTokens ?? 0) + (u.cacheWriteTokens ?? 0) + Math.max(0, u.outputTokens - reasoning) + delta
      }
      default:
        break
    }
  }
  return undefined
}

/**
 * The current turn's todo_write list (tool-todo/src/index.ts:131 - the projection
 * is cleared on turn/start), or undefined. The compaction summary never mentions
 * the list (compaction-basic/src/summarizer.ts), so after a compaction the model
 * stops seeing it: in one measured run the last todo_write came at step 136 of
 * 183 and the turn ended with items still in_progress/pending in the panel.
 */
export function openTodos(session) {
  for (let seq = session.seq - 1; seq >= 0; seq -= 1) {
    const e = session.eventAt(seq)
    if (e === undefined) continue
    if (e.type === 'todo/write') return e.data.todos
    if (e.type === 'turn/start') return undefined
  }
  return undefined
}

export default class CompactionNoTools extends Base {
  static name = 'compaction-basic-notools'
  static inject = Base.inject
  static Config = Base.Config

  async summarize(input, agent, signal) {
    const { tools: _tools, ...rest } = input
    // (3) Reasoning blocks are stripped from the summary replay here rather than
    // by the template: the summary goes to a DIFFERENT model entry, and pi-ai
    // (utils/transform-messages.js:68-90) turns thinking into ordinary assistant
    // text for a foreign model, which the template cannot tell apart. In one
    // measured turn 294k characters of reasoning since the last compaction made
    // the summary request 70982-118387 tokens, the server answered 400 sixteen
    // times in a row and the context kept growing until pi-ai's clamp cut the
    // output down. An assistant message that carried nothing but reasoning is
    // dropped whole: nothing refers to it (it holds no tool call).
    const messages = []
    for (const m of rest.messages) {
      if (m.role !== 'assistant' || !Array.isArray(m.content)) { messages.push(m); continue }
      const content = m.content.filter((b) => b.type !== 'reasoning')
      if (content.length === 0) continue
      messages.push({ ...m, content })
    }
    const result = await super.summarize({ ...rest, messages }, agent, signal)
    // (4) The todo_write list is appended to the summary so that after a
    // compaction the model keeps maintaining it and closes it before the final
    // answer.
    const todos = openTodos(agent.session)
    if (Array.isArray(todos) && todos.length > 0) {
      const lines = todos.map((t) => `- [${t.status}] ${t.content}`).join('\n')
      result.summary = [
        ...result.summary,
        { type: 'text', text: `\n\nActive todo_write list (keep it current; mark every item completed before the final answer):\n${lines}` },
      ]
    }
    return result
  }

  async compactIfNeeded(agent, trigger, signal) {
    if (trigger === 'context-overflow') return super.compactIfNeeded(agent, trigger, signal)
    const route = agent.session.requestHeader()?.config
    const real = usageAnchoredTokens(agent.session)
    if (route !== undefined && real !== undefined) {
      const info = await this.ctx.llm.resolveModelInfo(route.provider, route.model, signal)
      const window = info?.context?.contextWindow
      if (typeof window === 'number') {
        const threshold = Math.floor(window * this.config.thresholdRatio)
        if (real < threshold) return null
      }
    }
    return super.compactIfNeeded(agent, trigger, signal)
  }
}
