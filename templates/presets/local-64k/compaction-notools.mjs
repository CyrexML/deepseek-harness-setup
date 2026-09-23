/**
 * compaction-basic для стенда: (1) пересказ без каталога инструментов,
 * (2) порог сжатия по usage llama-server, а не по оценке метра,
 * (3) пересказ без reasoning-блоков в реплее (см. summarize()).
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
    const result = await super.summarize({ ...rest, messages }, agent, signal)
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
