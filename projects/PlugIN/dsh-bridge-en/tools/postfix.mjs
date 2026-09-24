// Make host-UI label matchers bilingual (DSH host renders English labels when locale=en).
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
// Plugin files are hardlinks into the pnpm store: writing in place would corrupt
// the store copy, so the file is unlinked first (new inode) and then written.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

const [file] = process.argv.slice(2);
let s = readFileSync(file, 'utf8');
const R = [
  [`document.querySelector('button[aria-label*="打开侧边栏"], button[title*="打开侧边栏"]')`,
   `document.querySelector('button[aria-label*="打开侧边栏"], button[title*="打开侧边栏"], button[aria-label*="Open sidebar"], button[title*="Open sidebar"]')`],
  [`document.querySelector('button[aria-label="新建会话"]')`,
   `document.querySelector('button[aria-label="新建会话"], button[aria-label="New session"]')`],
  [`e.target.closest('button[aria-label*="面板"], button[aria-label*="工作区"], div[class*="toggleCluster"] button,`,
   `e.target.closest('button[aria-label*="面板"], button[aria-label*="工作区"], button[aria-label*="panel"], button[aria-label*="orkspace"], div[class*="toggleCluster"] button,`],
  [`e.target.closest('button[aria-label*="收起侧边栏"], button[title*="收起侧边栏"]')`,
   `e.target.closest('button[aria-label*="收起侧边栏"], button[title*="收起侧边栏"], button[aria-label*="Collapse sidebar"], button[title*="Collapse sidebar"]')`],
  [`          label.includes('操作') ||\n          label.includes('视图') ||\n          label.includes('Add') ||\n          label.includes('搜索') ||\n          label.includes('设置') ||`,
   `          label.includes('操作') || label.includes('actions') ||\n          label.includes('视图') || label.includes('View') ||\n          /添加/.test(label) || label.includes('Add') ||\n          label.includes('搜索') || label.includes('Search') ||\n          label.includes('设置') || label.includes('Settings') ||`],
  [`if (label.includes('New Session') || btn.matches('button[class*="newSession"]'))`,
   `if (/新会话/.test(label) || label.includes('New session') || label.includes('New Session') || btn.matches('button[class*="newSession"]'))`],
  [`sessionRow.querySelector('button[aria-label*="操作"], button[class*="iconButton"], button')`,
   `sessionRow.querySelector('button[aria-label*="操作"], button[aria-label*="actions"], button[class*="iconButton"], button')`],
  [`      label.includes('添加工作区') ||\n      label.includes('打开工作区') ||\n      label.includes('打开文件夹') ||\n      btn.matches('button[aria-label*="工作区"][aria-label*="添加"], button[aria-label*="工作区"][aria-label*="打开"]')`,
   `      label.includes('添加工作区') ||\n      label.includes('打开工作区') ||\n      label.includes('打开文件夹') ||\n      label.includes('Add workspace') ||\n      label.includes('Open workspace') ||\n      label.includes('Open folder') ||\n      btn.matches('button[aria-label*="工作区"][aria-label*="添加"], button[aria-label*="工作区"][aria-label*="打开"], button[aria-label*="orkspace"][aria-label*="Add"], button[aria-label*="orkspace"][aria-label*="Open"]')`],
  // 2.10.10: template literal the extractor cannot key (embedded ${} expression)
  ["`本机可用：${(presetOptions.presets ?? []).map((p) => p.id).join(' / ') || '(None)'}`",
   "`Available on this machine: ${(presetOptions.presets ?? []).map((p) => p.id).join(' / ') || '(None)'}`"],
];
let applied = 0, skipped = 0;
for (const [a, b] of R) {
  if (s.includes(b)) { skipped++; continue; } // already applied (idempotent re-run)
  const n = s.split(a).length - 1;
  if (n === 0) { console.warn('WARN postfix: anchor not found (skipped — upstream code changed or already rewritten by another patch):', JSON.stringify(a.slice(0, 70))); skipped++; continue; }
  if (n !== 1) { console.error('MATCH COUNT', n, a.slice(0, 60)); process.exit(1); }
  s = s.replace(a, b); applied++;
}
unlinkWrite(file, s);
console.log(`postfix applied ${applied}, already present ${skipped}`);
