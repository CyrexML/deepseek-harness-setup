// Приведение наших пресетов (~/.dsh/.agent-presets/*/agent.cordis.yml) к схеме
// той версии харнеса, что сейчас собрана. Пресеты написаны под 0.1.3, а в
// 0.1.5/0.1.6 часть строк переименована — сессия тогда не стартует, а в
// интерфейсе это выглядит как «промпт не отправляется»: причина уходит только
// в ответ RPC (`preset "local-64k" failed to mount: …`).
//
// Что переносим (2026-09-23):
//   1. движок workflow: id/имя `workflow-worker-thread`
//      (@deepseek-ai/dsh-workflow-worker-thread) ↔ `workflow-ptc`
//      (@deepseek-ai/dsh-workflow-ptc);
//   2. persona: ключ конфига `text:` ↔ `prefix:`.
//
// Направление выбирается по версии харнеса: ≥ 0.1.5 — новая схема, иначе старая.
// Скрипт идемпотентен и симметричен, поэтому годится и для отката; вызывается из
// scripts/update-dsh.sh после смены тега. Резервные копии — в run/backups/keep/.
import { readFileSync, writeFileSync, existsSync, readdirSync, copyFileSync } from 'node:fs';
import { join } from 'node:path';

const root = process.env.DSH_ROOT || `${process.env.HOME}/tools/deepseek-harness`;
const presets = `${process.env.HOME}/.dsh/.agent-presets`;
const keep = `${process.env.HOME}/Harness_AI/run/backups/keep`;
const version = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')).version;
const [maj, min, pat] = version.split('-')[0].split('.').map(Number);
const NEW = maj > 0 || min > 1 || (min === 1 && pat >= 5);

// [старое, новое] — построчные замены в agent.cordis.yml
const RULES = [
  ['- id: workflow-worker-thread', '- id: workflow-ptc'],
  ["'@deepseek-ai/dsh-workflow-worker-thread'", "'@deepseek-ai/dsh-workflow-ptc'"],
  ['    text: >-', '    prefix: >-'],   // строка persona (только внутри строки persona, см. ниже)
];

const stamp = new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);
let changed = 0;
for (const dir of readdirSync(presets, { withFileTypes: true }).filter(d => d.isDirectory())) {
  const path = join(presets, dir.name, 'agent.cordis.yml');
  if (!existsSync(path)) continue;
  const before = readFileSync(path, 'utf8');
  let s = before;
  for (const [oldText, newText] of RULES) {
    const from = NEW ? oldText : newText;
    const to = NEW ? newText : oldText;
    if (from.trim().startsWith('text:') || from.trim().startsWith('prefix:')) {
      // persona: меняем только ключ внутри её блока
      const at = s.indexOf("- id: persona");
      if (at === -1) continue;
      const end = s.indexOf('\n- id:', at + 1);
      const block = s.slice(at, end === -1 ? undefined : end);
      if (!block.includes(from)) continue;
      s = s.slice(0, at) + block.replace(from, to) + (end === -1 ? '' : s.slice(end));
      continue;
    }
    s = s.split(from).join(to);
  }
  if (s !== before) {
    copyFileSync(path, join(keep, `agent.cordis.yml-${dir.name}-${stamp}`));
    writeFileSync(path, s);
    changed++;
    console.log(`preset-migrate: ${dir.name} → схема ${NEW ? '0.1.5+' : '0.1.3'} (бэкап в run/backups/keep)`);
  }
}
if (changed === 0) console.log(`preset-migrate: пресеты уже под схему ${NEW ? '0.1.5+' : '0.1.3'} (харнес ${version})`);
