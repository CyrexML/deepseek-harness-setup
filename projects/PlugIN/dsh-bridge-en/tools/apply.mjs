// Apply translation maps to plugin sources. Usage: node apply.mjs <root> <relfile...>
import { readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
// Плагины лежат в pnpm-store хардлинками: запись «по месту» испортила бы копию в store,
// поэтому файл сначала удаляется (новый inode), потом пишется.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

import { join } from 'node:path';
import * as acorn from 'acorn';
import * as walk from 'acorn-walk';

const HAN = /\p{Script=Han}/u;
const here = (f) => new URL(f, import.meta.url);
const [root, ...files] = process.argv.slice(2);

// ---- build key -> english map
const strings = [...JSON.parse(readFileSync(here('strings.json'), 'utf8'))];
const extra = JSON.parse(readFileSync(here('strings-extra.json'), 'utf8'));
const tr = {};
for (const f of ['tr-1', 'tr-2', 'tr-3', 'tr-4', 'tr-5', 'tr-6']) Object.assign(tr, JSON.parse(readFileSync(here(f + '.json'), 'utf8')));
const keep = new Set(JSON.parse(readFileSync(here('keep.json'), 'utf8')));
const overrides = JSON.parse(readFileSync(here('overrides.json'), 'utf8'));
const map = new Map();
const keepKeys = new Set();
const isSelector = (k) => /\[(aria-label|title|class)\*?=/.test(k); // host-UI CSS selectors stay as-is (postfix.mjs makes them bilingual)
function fragApply(idx, key) {
  let t = key;
  for (const [a, b] of JSON.parse(readFileSync(here(`frag-${idx}.json`), 'utf8'))) t = t.split(a).join(b);
  return t;
}
function register(idx, key) {
  if (keep.has(idx)) { keepKeys.add(key); return; }
  if (tr[idx] !== undefined) { map.set(key, tr[idx]); return; }
  if (existsSync(here(`frag-${idx}.json`))) { map.set(key, fragApply(idx, key)); return; }
  // untranslated big literal (CSS comments / polyfill) -> keep
  keepKeys.add(key);
}
strings.forEach((s, i) => register(i, s.key));
extra.forEach((s, i) => register(1000 + i, s.key));
// machine translations (auto-translate.mjs) — keyed by Chinese text, lowest priority
if (existsSync(here('tr-auto.json'))) for (const [k, v] of Object.entries(JSON.parse(readFileSync(here('tr-auto.json'), 'utf8')))) if (!map.has(k) && !keepKeys.has(k)) map.set(k, v);

// ---- helpers
function esc(str, q) {
  return str.replace(/\\/g, '\\\\').replace(new RegExp(q, 'g'), '\\' + q).replace(/\n/g, '\\n').replace(/\r/g, '\\r');
}
function escTpl(str, multiline) {
  let s = str.replace(/\\/g, '\\\\').replace(/`/g, '\\`').replace(/\$\{/g, '\\${');
  if (!multiline) s = s.replace(/\n/g, '\\n').replace(/\r/g, '\\r');
  return s;
}
function collect(src, rel) {
  const ast = acorn.parse(src, { ecmaVersion: 'latest', sourceType: 'module', locations: true, allowHashBang: true });
  const parents = new WeakMap();
  walk.full(ast, (node) => {
    for (const k of Object.keys(node)) {
      const v = node[k];
      if (v && typeof v === 'object') {
        if (Array.isArray(v)) v.forEach(c => c && typeof c.type === 'string' && parents.set(c, node));
        else if (typeof v.type === 'string') parents.set(v, node);
      }
    }
  });
  const ctxOf = (node) => {
    const p = parents.get(node);
    if (!p) return '';
    if (p.type === 'Property' && p.key === node) return 'objkey';
    if (p.type === 'BinaryExpression') return 'cmp';
    if (p.type === 'SwitchCase') return 'case';
    if (p.type === 'CallExpression' && p.arguments.includes(node) && p.callee.type === 'MemberExpression' && p.callee.property.type === 'Identifier')
      return 'call:' + p.callee.property.name;
    return '';
  };
  const occ = [];
  walk.full(ast, (node) => {
    if (node.type === 'Literal' && typeof node.value === 'string' && HAN.test(node.value)) {
      occ.push({ line: node.loc.start.line, start: node.start, end: node.end, kind: 'str', key: node.value, q: src[node.start], ctx: ctxOf(node) });
    } else if (node.type === 'TemplateLiteral' && node.quasis.some(q => HAN.test(q.value.cooked ?? ''))) {
      if (parents.get(node)?.type === 'TaggedTemplateExpression') return;
      let key = '';
      node.quasis.forEach((q, i) => { key += (q.value.cooked ?? q.value.raw); if (i < node.expressions.length) key += `{${i}}`; });
      occ.push({ line: node.loc.start.line, start: node.start, end: node.end, kind: 'tpl', key, ctx: ctxOf(node), exprs: node.expressions.map(e => src.slice(e.start, e.end)), multiline: src.slice(node.start, node.end).includes('\n') });
    }
  });
  return occ;
}

let totalRepl = 0; const unmapped = []; const todo = new Map();
for (const rel of files) {
  const path = join(root, rel);
  let src = readFileSync(path, 'utf8');
  let fileRepl = 0;
  for (let pass = 0; pass < 6; pass++) {
    const occ = collect(src, rel);
    // leaves = occurrences not containing another occurrence
    const leaves = occ.filter(o => !occ.some(p => p !== o && p.start >= o.start && p.end <= o.end));
    const pending = leaves.filter(o => overrides[`${rel}:${o.line}|${o.key}`] !== undefined || overrides[`${rel}:${o.line}`] !== undefined || (!keepKeys.has(o.key) && !isSelector(o.key) && map.has(o.key)));
    for (const o of leaves) if (!map.has(o.key) && !keepKeys.has(o.key) && !isSelector(o.key) && overrides[`${rel}:${o.line}`] === undefined) { unmapped.push(`${rel}:${o.line} ${JSON.stringify(o.key).slice(0, 80)}`); const t = todo.get(o.key) || { key: o.key, where: [], ctx: new Set() }; t.where.push(`${rel}:${o.line}`); if (o.ctx) t.ctx.add(o.ctx); todo.set(o.key, t); }
    if (!pending.length) break;
    pending.sort((a, b) => b.start - a.start);
    for (const o of pending) {
      const en = overrides[`${rel}:${o.line}|${o.key}`] ?? overrides[`${rel}:${o.line}`] ?? map.get(o.key);
      let out;
      if (o.kind === 'str') out = o.q + esc(en, o.q) + o.q;
      else {
        const parts = en.split(/(\{\d+\})/);
        out = '`' + parts.map(p => { const m = /^\{(\d+)\}$/.exec(p); return m ? '${' + o.exprs[+m[1]] + '}' : escTpl(p, o.multiline); }).join('') + '`';
      }
      src = src.slice(0, o.start) + out + src.slice(o.end);
      fileRepl++;
    }
  }
  if (fileRepl) { unlinkWrite(path, src); totalRepl += fileRepl; }
  // final residual report
  const res = collect(src, rel).filter(o => !keepKeys.has(o.key) && !isSelector(o.key));
  const resLeaf = res.filter(o => !res.some(p => p !== o && p.start >= o.start && p.end <= o.end));
  console.log(`${rel}: replaced=${fileRepl} residual=${resLeaf.length}`);
}
console.log('TOTAL replaced', totalRepl);
writeFileSync(here('todo.json'), JSON.stringify([...todo.values()].map(t => ({ ...t, ctx: [...t.ctx] })), null, 1));
if (unmapped.length) { console.log('UNMAPPED (written to tools/todo.json):'); console.log([...new Set(unmapped)].join('\n')); }
