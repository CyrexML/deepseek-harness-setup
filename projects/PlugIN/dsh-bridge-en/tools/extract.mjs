// Extract CJK-bearing string/template literals from JS files using acorn (comments ignored).
// Usage: node extract.mjs <root> <relfile...>  -> writes strings.json (unique keys) and occ.json (occurrences)
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import * as acorn from 'acorn';
import * as walk from 'acorn-walk';

const HAN = /\p{Script=Han}/u;
const [root, ...files] = process.argv.slice(2);
const occ = [];
const parents = new WeakMap();

function ctxOf(node) {
  const p = parents.get(node);
  if (!p) return '';
  if (p.type === 'Property' && p.key === node) return 'objkey';
  if (p.type === 'BinaryExpression') return 'cmp:' + p.operator;
  if (p.type === 'CallExpression' && p.arguments.includes(node)) {
    const c = p.callee;
    if (c.type === 'MemberExpression' && c.property.type === 'Identifier') return 'call:' + c.property.name;
    if (c.type === 'Identifier') return 'call:' + c.name;
  }
  if (p.type === 'SwitchCase') return 'case';
  return p.type;
}

for (const rel of files) {
  const src = readFileSync(join(root, rel), 'utf8');
  let ast;
  try {
    ast = acorn.parse(src, { ecmaVersion: 'latest', sourceType: 'module', locations: true, allowHashBang: true });
  } catch (e) { console.error('PARSE FAIL', rel, e.message); continue; }
  // build parent links
  walk.full(ast, (node) => {
    for (const k of Object.keys(node)) {
      const v = node[k];
      if (v && typeof v === 'object') {
        if (Array.isArray(v)) v.forEach(c => c && typeof c.type === 'string' && parents.set(c, node));
        else if (typeof v.type === 'string') parents.set(v, node);
      }
    }
  });
  walk.full(ast, (node) => {
    if (node.type === 'Literal' && typeof node.value === 'string' && HAN.test(node.value)) {
      occ.push({ f: rel, line: node.loc.start.line, start: node.start, end: node.end, kind: 'str', key: node.value, ctx: ctxOf(node) });
    } else if (node.type === 'TemplateLiteral' && node.quasis.some(q => HAN.test(q.value.cooked ?? ''))) {
      if (parents.get(node)?.type === 'TaggedTemplateExpression') return;
      let key = '';
      node.quasis.forEach((q, i) => { key += (q.value.cooked ?? q.value.raw); if (i < node.expressions.length) key += `{${i}}`; });
      const exprs = node.expressions.map(e => src.slice(e.start, e.end));
      occ.push({ f: rel, line: node.loc.start.line, start: node.start, end: node.end, kind: 'tpl', key, exprs, ctx: ctxOf(node) });
    }
  });
}
// tpl nodes may nest (template inside ${} of another template): drop inner ones contained in an outer occurrence of same file
occ.sort((a, b) => a.f.localeCompare(b.f) || a.start - b.start);
const kept = [];
for (const o of occ) {
  const outer = kept.find(k => k.f === o.f && k.start <= o.start && k.end >= o.end);
  if (outer) { o.nested = true; }
  kept.push(o);
}
const uniq = new Map();
for (const o of kept) {
  if (o.nested) continue;
  const u = uniq.get(o.key) || { n: 0, files: new Set(), ctx: new Set() };
  u.n++; u.files.add(o.f); if (o.ctx) u.ctx.add(o.ctx); uniq.set(o.key, u);
}
const out = [...uniq.entries()].map(([key, u]) => ({ key, n: u.n, len: key.length, files: [...u.files], ctx: [...u.ctx] }));
writeFileSync(new URL('occ.json', import.meta.url), JSON.stringify(kept, null, 0));
writeFileSync(new URL('strings.json', import.meta.url), JSON.stringify(out, null, 1));
const big = out.filter(s => s.len > 400);
console.log(`occurrences=${kept.length} unique=${out.length} big(>400)=${big.length} totalChars=${out.reduce((a, s) => a + s.len, 0)}`);
for (const b of big) console.log(`  BIG len=${b.len} ${b.files.join(',')} :: ${b.key.slice(0, 60).replace(/\n/g, ' ')}`);
