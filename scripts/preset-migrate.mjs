// Bring the stand's presets (~/.dsh/.agent-presets/*/agent.cordis.yml) in line
// with the schema of the harness version currently built. The presets were
// written for 0.1.3 and some rows were renamed in 0.1.5/0.1.6; the session then
// fails to start, which in the interface looks like "the prompt is not sent" -
// the reason only appears in the RPC reply (`preset "local-64k" failed to
// mount: ...`).
//
// What is migrated:
//   1. the workflow engine: id/name `workflow-worker-thread`
//      (@deepseek-ai/dsh-workflow-worker-thread) ↔ `workflow-ptc`
//      (@deepseek-ai/dsh-workflow-ptc);
//   2. persona: the config key `text:` <-> `prefix:`.
//
// The direction follows the harness version: 0.1.5 and above get the new schema,
// anything older the previous one. The script is idempotent and symmetric, so it
// also serves as a rollback; update-dsh.sh calls it after a tag switch. Backups
// go into run/backups/keep/.
import { readFileSync, writeFileSync, existsSync, readdirSync, copyFileSync } from 'node:fs';
import { join } from 'node:path';

const root = process.env.DSH_ROOT || `${process.env.HOME}/tools/deepseek-harness`;
const presets = `${process.env.HOME}/.dsh/.agent-presets`;
const keep = `${process.env.HOME}/Harness_AI/run/backups/keep`;
const version = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8')).version;
const [maj, min, pat] = version.split('-')[0].split('.').map(Number);
const NEW = maj > 0 || min > 1 || (min === 1 && pat >= 5);

// [old, new] - line replacements in agent.cordis.yml
const RULES = [
  ['- id: workflow-worker-thread', '- id: workflow-ptc'],
  ["'@deepseek-ai/dsh-workflow-worker-thread'", "'@deepseek-ai/dsh-workflow-ptc'"],
  ['    text: >-', '    prefix: >-'],   // persona row only (see below)
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
      // persona: only the key inside its own block is changed
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
    console.log(`preset-migrate: ${dir.name} -> schema ${NEW ? '0.1.5+' : '0.1.3'} (backup in run/backups/keep)`);
  }
}
if (changed === 0) console.log(`preset-migrate: presets already match schema ${NEW ? '0.1.5+' : '0.1.3'} (harness ${version})`);
