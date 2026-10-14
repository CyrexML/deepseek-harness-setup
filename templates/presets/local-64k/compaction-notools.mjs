/**
 * compaction-basic для стенда: (1) пересказ без каталога инструментов,
 * (2) порог сжатия по usage llama-server, а не по оценке метра,
 * (3) пересказ без reasoning-блоков в реплее (см. summarize()),
 * (5) пересказ, оказавшийся вызовом инструмента, не принимается (см. looksLikeToolCall).
 *
 * (1) Замер по логам 2026-09-11/12: из 36 сжатий сессии 317a9aa7 23 закончились
 * "summarization produced no text summary content" за 3-20 с каждое; в
 * c47f7d3f — 33 из 73. summarizer.ts §summarizeWithLlm реплеит разговор ВМЕСТЕ
 * со схемами инструментов (ради префикс-кэша) и просит модель «не звать
 * инструменты» текстом. Модель посреди tool-цикла отвечает tool-call, текста
 * нет, компактор бросает ошибку, порог остаётся перейдённым, и попытка
 * повторяется на каждом следующем шаге, пока контекст растёт. Ручки в схеме
 * компактора нет (config.ts §27), но `summarize()` объявлен единственным хуком
 * подкласса (index.ts:231). Здесь он вызывается без `tools`: без каталога
 * tool-call невозможен физически. Цена: системное сообщение шаблона Qwen
 * начинается с блока tools, префикс-кэш для запроса пересказа не совпадает —
 * полный префилл ~40k токенов, ~25-30 с при 1 500 т/с.
 *
 * (2) С 2026-09-12 сервер работает на qwen3.8-agent.jinja: reasoning прошлых
 * шагов в промпт не реплеится, и usage сервера стал заметно МЕНЬШЕ оценки
 * метра (token-meter/src/estimate.ts считает reasoning-блоки по chars/4).
 * Метр берёт usage только когда usage >= оценки (token-meter/src/index.ts:166),
 * иначе — оценку. Итог замера 13d5fe23 (первая сессия на новом шаблоне):
 * сжатия при реальных 26 237 и 23 901 токенах при пороге 45 875. Здесь перед
 * штатной проверкой считается реальный контекст: usage последнего вызова
 * (input + cacheRead + output) плюс оценка того, что легло в surface после него
 * (результаты инструментов, вставки). Ниже порога — сжатие не запускается.
 * После сжатия, пока нового ответа модели нет, usage устарел — решает штатная
 * логика. Триггер context-overflow не перехватывается никогда.
 *
 * Импорт по абсолютному пути: пресет лежит под ~/.dsh, и восходящий поиск
 * node_modules до пакетов харнесса не доходит (agent-presets/src/mount.ts §import
 * решает это только для спецификатора строки, не для импортов внутри файла).
 * Путь совпадает с тем, что грузит сам хост, поэтому экземпляр модуля один.
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
 * Реальный контекст по usage последнего ответа модели, или undefined, если
 * после него было сжатие (usage устарел) или usage вовсе нет.
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
        // Шаблон qwen3.8-agent.jinja не реплеит reasoning и последнего ответа,
        // поэтому из outputTokens вычитаются его reasoning-токены (по чанкам
        // потока; без потока — по символам).
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
 * Действующий список todo_write текущего хода (tool-todo/src/index.ts:131 —
 * проекция очищается на turn/start), или undefined. Пересказ сжатия список не
 * упоминает (compaction-basic/src/summarizer.ts), и после сжатия модель его не
 * видит: эталон 14, прогон 3 — последний todo_write на шаге 136 из 183, ход
 * закрыт с пунктами in_progress/pending в панели.
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

/**
 * (5) Пересказ, который на деле — вызов инструмента. Без каталога инструментов
 * модель не может ВЫЗВАТЬ инструмент, но пишет вызов ТЕКСТОМ: вся реплеенная
 * история состоит из таких вызовов, и шаблон Qwen рисует их тем же XML. Базовый
 * класс принимает любой непустой текст, и в сессию ложится «пересказ» из одной
 * строки вроде `<tool_call><function=bash>ls -la …`. Замер 2026-10-14 (проект
 * Presentation): 7 из 13 сжатий двух сессий — такие; всё, что агент знал о
 * десятках шагов, заменялось одной командой и списком задач. Отсюда повторное
 * чтение файлов, задачи «in_progress» по 20 шагов и выводы, давно опровергнутые.
 */
const TOOL_CALL_MARKUP = /<tool_call>|<function=|<parameter=/
export function looksLikeToolCall(summary) {
  const text = (summary ?? []).map((b) => (typeof b?.text === 'string' ? b.text : '')).join('').trim()
  if (text.length === 0) return true
  if (/^(<tool_call>|<function=)/.test(text)) return true
  // Настоящий пересказ — это разделы «## …»; разметка вызова без единого раздела — не он.
  return !/^##\s/m.test(text) && TOOL_CALL_MARKUP.test(text)
}

function blocksText(content) {
  if (typeof content === 'string') return content
  const out = []
  for (const b of content ?? []) {
    if (!b || typeof b !== 'object') continue
    if (b.type === 'text' && typeof b.text === 'string') out.push(b.text)
    else if (b.type === 'image' || b.type === 'file') out.push(`[${b.type}]`)
  }
  return out.join('\n')
}
const clip = (s, n) => (s.length <= n ? s : `${s.slice(0, n)} …[+${s.length - n} chars]`)

/**
 * История для повторной попытки: вызовы инструментов и их результаты переписаны
 * обычным текстом, так что в запросе нет ни одного блока tool-call и шаблону
 * нечего рисовать как <tool_call>. Результаты урезаются — для пересказа нужна их
 * суть, а не полный вывод.
 */
export function flattenToolTraffic(messages) {
  const names = new Map()
  const out = []
  const push = (m) => {
    const last = out[out.length - 1]
    if (last && last.role === m.role && (m.role === 'user' || m.role === 'assistant')) {
      out[out.length - 1] = { ...last, content: [...last.content, { type: 'text', text: '\n\n' }, ...m.content] }
    } else out.push(m)
  }
  for (const m of messages) {
    if (m.role === 'assistant' && Array.isArray(m.content)) {
      const parts = []
      for (const b of m.content) {
        if (b.type === 'text' && b.text.trim()) parts.push(b.text)
        else if (b.type === 'tool-call') { names.set(b.id, b.name); parts.push(`[tool call] ${b.name} ${clip(String(b.arguments ?? ''), 400)}`) }
      }
      if (parts.length) push({ ...m, content: [{ type: 'text', text: parts.join('\n') }] })
    } else if (m.role === 'tool') {
      const text = `[tool result: ${names.get(m.toolCallId) ?? 'tool'}${m.isError ? ', error' : ''}]\n${clip(blocksText(m.content), 1500)}`
      const { toolCallId: _id, isError: _e, ...rest } = m
      push({ ...rest, role: 'user', source: { kind: 'user' }, content: [{ type: 'text', text }] })
    } else push(m)
  }
  return out
}

/**
 * Последний рубеж: пересказ, собранный из самой истории без модели. Хуже
 * модельного, но несравнимо лучше одной строки с командой: в нём запросы
 * пользователя дословно, прежний пересказ, файлы и последнее, что агент сказал.
 */
export function mechanicalSummary(messages) {
  const requests = [], subagents = [], written = new Set(), read = new Set()
  let prior = '', lastSaid = ''
  for (const m of messages) {
    const kind = m.source?.kind
    if (m.role === 'user' && kind === 'user') requests.push(clip(blocksText(m.content).trim(), 1500))
    else if (m.role === 'user' && kind === 'compact-checkpoint') {
      const t = blocksText(m.content), a = t.indexOf('<compacted-summary>'), z = t.lastIndexOf('</compacted-summary>')
      prior = clip((a >= 0 ? t.slice(a + 19, z > a ? z : undefined) : t).trim(), 5000)
    } else if (m.role === 'user' && kind === 'subagent-settled') subagents.push(clip(blocksText(m.content).trim(), 300))
    else if (m.role === 'assistant' && Array.isArray(m.content)) {
      const said = m.content.filter((b) => b.type === 'text').map((b) => b.text).join('\n').trim()
      if (said) lastSaid = said
      for (const b of m.content) {
        if (b.type !== 'tool-call') continue
        let args = {}
        try { args = JSON.parse(b.arguments) } catch { /* разметка без JSON */ }
        const p = args.file_path ?? args.path ?? args.source
        if (typeof p !== 'string') continue
        if (b.name === 'write' || b.name === 'edit') written.add(p)
        else if (b.name === 'read') read.add(p)
      }
    }
  }
  const list = (xs) => (xs.length ? xs.map((x) => `- ${x}`).join('\n') : '- (none)')
  return [
    '(Checkpoint assembled from the transcript itself: the model returned a tool call instead of a summary twice. User requests are verbatim; verify file state before relying on it.)',
    '',
    '## Primary Request and Intent',
    list(requests.slice(-4)),
    '',
    '## Prior Checkpoint',
    prior || '(none)',
    '',
    '## Files and Code',
    list([...[...written].slice(-30).map((p) => `written/edited: ${p}`), ...[...read].slice(-20).map((p) => `read: ${p}`)]),
    '',
    '## Subagent Results',
    list(subagents.slice(-5)),
    '',
    '## Current Work',
    `- Last thing the agent said: ${clip(lastSaid || '(none)', 1500)}`,
    '',
    '## Next Step',
    '- Re-read the todo list below and the files listed above, then continue the most recent user request.',
  ].join('\n')
}

export default class CompactionNoTools extends Base {
  static name = 'compaction-basic-notools'
  static inject = Base.inject
  static Config = Base.Config

  async summarize(input, agent, signal) {
    const { tools: _tools, ...rest } = input
    // (3) Reasoning-блоки из реплея пересказа вырезаются здесь, а не шаблоном:
    // пересказ идёт на ДРУГУЮ запись модели (qwen38-27b-nothink), и pi-ai
    // (utils/transform-messages.js:68-90) для чужой модели превращает thinking
    // в обычный текст assistant-сообщения — шаблон такой текст не отличает.
    // Эталон 14, ход 5: 294k символов reasoning с последнего сжатия → запрос
    // пересказа 70 982…118 387 токенов → 400 от сервера, 16 провалов подряд,
    // контекст рос, пока клэмп pi-ai не дожал вывод до 2 181 токена.
    // Assistant-сообщение, в котором кроме reasoning ничего не было, выбрасывается
    // целиком: на него никто не ссылается (tool-call в нём нет).
    const messages = []
    for (const m of rest.messages) {
      if (m.role !== 'assistant' || !Array.isArray(m.content)) { messages.push(m); continue }
      const content = m.content.filter((b) => b.type !== 'reasoning')
      if (content.length === 0) continue
      messages.push({ ...m, content })
    }
    // (5) Пересказ-вызов: повтор на истории без tool-call блоков, затем сборка без модели.
    let result = await super.summarize({ ...rest, messages }, agent, signal)
    if (looksLikeToolCall(result.summary)) {
      console.warn(`[compaction-notools] session ${agent.session.id}: summary was a tool call, retrying on a flattened transcript`)
      try {
        result = await super.summarize({ ...rest, messages: flattenToolTraffic(messages) }, agent, signal)
      } catch (error) {
        console.warn(`[compaction-notools] retry failed: ${error?.message ?? error}`)
      }
      if (looksLikeToolCall(result.summary)) {
        console.warn(`[compaction-notools] session ${agent.session.id}: retry was a tool call too, using the mechanical checkpoint`)
        result = { summary: [{ type: 'text', text: mechanicalSummary(messages) }], provider: result.provider, model: result.model, maxTokens: result.maxTokens }
      }
    }
    // (4) Список todo_write дописывается к пересказу, чтобы после сжатия модель
    // продолжала его вести и закрыла перед финальным ответом.
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

  // compactIfNeeded is NOT overridden any more (2026-10-02).
  //
  // It used to veto a pressure compaction when `usageAnchoredTokens` said the
  // real context was still below thresholdRatio - an anchor that walked back to
  // the last assistant's server-reported usage, so it did not count the replayed
  // reasoning the local template never sends. That saved compactions on 0.1.6.
  //
  // On 0.1.7 the anchor misjudges and the veto SUPPRESSES compaction outright:
  // graph-memory writes a `compaction/prune` on every turn boundary, and the
  // anchor gives up at the first one (returns undefined) or, past it, measures a
  // prefix that has since been rewritten. Measured on a live session: the anchor
  // reported 7 790 tokens against a 45 875 threshold while the prompt actually
  // sent to llama-server reached 65 536 - the full window - so nothing was ever
  // compacted and every long turn ended on "Output token limit reached".
  //
  // The base engine measures with the host's own tokenMeter, which tracks what
  // the model is really sent. Deciding WHEN to compact belongs to it; what this
  // class is for is HOW the summary is made (summarize() above, without the tool
  // catalog). usageAnchoredTokens stays exported - it is still right where no
  // prune intervenes, and the token-meter report uses it.
}
