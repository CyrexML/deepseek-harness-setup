// Translate strings listed in todo.json (written by apply.mjs) with the local llama-server (OpenAI-compatible API).
// Writes/updates tr-auto.json (Chinese key -> English). Matcher-like strings (compared/included/object keys) are
// NOT auto-translated — they are listed for manual review since a wrong translation could break logic.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { execSync } from 'node:child_process';

const here = (f) => new URL(f, import.meta.url);
const HAN = /\p{Script=Han}/u;
const RISKY = /^(cmp|case|objkey|call:(includes|startsWith|endsWith|indexOf|match|matches|test|querySelector|querySelectorAll|closest))$/;

function baseUrl() {
  if (process.env.DSH_LLAMA_BASE_URL) return process.env.DSH_LLAMA_BASE_URL.replace(/\/$/, '');
  // WSL: the Windows host is the default gateway
  let gw = 'localhost';
  try { gw = execSync("ip route | awk '/default/{print $3; exit}'").toString().trim() || gw; } catch {}
  return `http://${gw}:8080/v1`;
}
const BASE = baseUrl();
const todo = existsSync(here('todo.json')) ? JSON.parse(readFileSync(here('todo.json'), 'utf8')) : [];
const auto = existsSync(here('tr-auto.json')) ? JSON.parse(readFileSync(here('tr-auto.json'), 'utf8')) : {};
const review = [];
const work = [];
for (const t of todo) {
  if (auto[t.key] !== undefined) continue;
  if (t.ctx.some(c => RISKY.test(c))) { review.push(t); continue; }
  work.push(t);
}
console.log(`todo=${todo.length} to-translate=${work.length} review=${review.length} endpoint=${BASE}`);

const SYSTEM = `You translate UI strings of a Node.js/React plugin ("dsh-bridge" for DeepSeek Harness) from Simplified Chinese to natural, concise English.
Rules:
- Keep placeholders exactly: {0} {1} ..., %s %d, \${...}, and keep markdown (**, \`, |, >, #), emoji, HTML tags/attributes, URLs, and code identifiers unchanged.
- Keep leading/trailing spaces and newlines (\\n) as in the source.
- Product terms: 工作区=workspace, 会话=session, 隧道=tunnel, 局域网=LAN, 公网=public network, 管理密码=admin password, 访问密码=access password, 安全认证=Security, 飞书=Feishu, 微信=WeChat.
- Do not add explanations. Return ONLY JSON: {"t": ["translation 1", "translation 2", ...]} in the same order and count as the input array.`;

async function translateBatch(keys) {
  const body = {
    model: 'qwen38-27b-local',
    temperature: 0.1,
    max_tokens: 4096,
    chat_template_kwargs: { enable_thinking: false },
    response_format: { type: 'json_schema', json_schema: { name: 'tr', schema: { type: 'object', properties: { t: { type: 'array', items: { type: 'string' }, minItems: keys.length, maxItems: keys.length } }, required: ['t'] } } },
    messages: [
      { role: 'system', content: SYSTEM },
      { role: 'user', content: JSON.stringify(keys) },
    ],
  };
  const r = await fetch(`${BASE}/chat/completions`, { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${process.env.DSH_LLAMA_KEY || 'none'}` }, body: JSON.stringify(body) });
  if (!r.ok) throw new Error(`HTTP ${r.status}: ${(await r.text()).slice(0, 300)}`);
  const j = await r.json();
  const content = j.choices?.[0]?.message?.content ?? '';
  const m = content.match(/\{[\s\S]*\}/);
  return JSON.parse(m ? m[0] : content).t;
}
const ph = (s) => (s.match(/\{\d+\}|%[sd]/g) || []).sort().join(',');
let ok = 0, bad = 0;
for (let i = 0; i < work.length; i += 20) {
  const batch = work.slice(i, i + 20);
  const keys = batch.map(t => t.key);
  let out;
  try { out = await translateBatch(keys); } catch (e) { console.error('batch failed:', e.message); bad += keys.length; continue; }
  batch.forEach((t, k) => {
    const v = out?.[k];
    const good = typeof v === 'string' && v.trim() && !HAN.test(v) && ph(v) === ph(t.key);
    if (good) { auto[t.key] = v; ok++; } else { bad++; review.push({ ...t, reason: 'bad machine translation', got: v }); }
  });
  process.stdout.write(`  translated ${Math.min(i + 20, work.length)}/${work.length}\n`);
}
writeFileSync(here('tr-auto.json'), JSON.stringify(auto, null, 1));
writeFileSync(here('review.json'), JSON.stringify(review, null, 1));
console.log(`auto-translated ok=${ok} failed=${bad}; needs manual review: ${review.length} (tools/review.json)`);
for (const t of review) console.log(`  REVIEW ${t.where.join(',')} [${t.ctx.join(',')}] ${JSON.stringify(t.key).slice(0, 90)}${t.got !== undefined ? ' -> ' + JSON.stringify(t.got).slice(0, 60) : ''}`);
