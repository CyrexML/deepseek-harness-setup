// Headless smoke test of the patched dsh-bridge (run after translate.sh + web restart).
// usage: LD_LIBRARY_PATH=$HOME/.local/lib/asound/usr/lib/x86_64-linux-gnu node bridge-verify.mjs
// Checks on the phone layout (412px via LAN bridge): sidebar ⏻ button + dark popover inside the
// viewport, Settings tabs without horizontal overflow, Remote access panel renders; on desktop via
// 127.0.0.1:3080 (auto-unlocked admin): Remote access → Power tab shows the card. Screenshots go to
// ~/Harness_AI/run/verify/.
const DSH_ROOT = process.env.DSH_ROOT ?? `${process.env.HOME}/tools/deepseek-harness`;
// Playwright лежит в сторе pnpm под именем с версией, поэтому путь ИЩЕТСЯ: после
// обновления харнеса версия меняется. Берём не самую новую, а ту, чьи браузеры
// реально скачаны (~/.cache/ms-playwright): в сторе может лежать альфа, для
// которой браузеров нет, и запуск падает «Executable doesn't exist».
const { readdirSync: __rd, readFileSync: __rf, existsSync: __ex } = await import('node:fs');
const __pnpm = `${DSH_ROOT}/node_modules/.pnpm`;
const __candidates = __rd(__pnpm).filter((name) => /^playwright@\d/.test(name)).sort().reverse();
const __browsersDir = process.env.PLAYWRIGHT_BROWSERS_PATH ?? `${process.env.HOME}/.cache/ms-playwright`;
const __installed = __ex(__browsersDir) ? __rd(__browsersDir) : [];
const __chromiumRevision = (name) => {
  const registry = `${__pnpm}/${name}/node_modules/playwright-core/browsers.json`;
  if (!__ex(registry)) return undefined;
  return /"name":\s*"chromium"[\s\S]*?"revision":\s*"(\d+)"/.exec(__rf(registry, 'utf8'))?.[1];
};
const __pw = __candidates.find((name) => {
  const revision = __chromiumRevision(name);
  return revision !== undefined && __installed.some((dir) => dir.endsWith(`-${revision}`));
}) ?? __candidates[0];
if (__pw === undefined) throw new Error(`playwright не найден в ${__pnpm}`);
const __pwEntry = `${__pnpm}/${__pw}/node_modules/playwright/index.mjs`;
const { chromium, devices } = await import(__pwEntry);
import { readFileSync, mkdirSync } from 'node:fs';
import { execSync } from 'node:child_process';
const OUT = `${process.env.HOME}/Harness_AI/run/verify`; mkdirSync(OUT, { recursive: true });
const cookie = JSON.parse(readFileSync(`${process.env.HOME}/.dsh/dsh-bridge/sessions.json`, 'utf8')).at(-1)[0];
const lan = 'http://' + execSync('hostname -I').toString().trim().split(/\s+/)[0] + ':3082'; // WSL IP меняется при перезапуске
const local = readFileSync(`${process.env.HOME}/Harness_AI/run/web.log`, 'utf8').match(/dsh web: (http:\/\/\S+)/g).pop().replace('dsh web: ', '');
const browser = await chromium.launch({ env: { ...process.env, LD_LIBRARY_PATH: `${process.env.HOME}/.local/lib/asound/usr/lib/x86_64-linux-gnu` } }); // libasound из ~/.local, как в shot.mjs
const results = [];
const ok = (name, cond, extra = '') => { results.push(`${cond ? 'PASS' : 'FAIL'} ${name} ${extra}`); };
const dismiss = async (page) => { const c = page.locator('button', { hasText: 'Continue' }); if (await c.count()) { await c.first().click(); await page.waitForTimeout(600); } };

// --- phone via LAN bridge
{
  const ctx = await browser.newContext({ viewport: { width: 412, height: 900 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true, userAgent: devices['Pixel 7'].userAgent });
  await ctx.addCookies([{ name: 'dsh_bridge_auth', value: cookie, url: lan }]);
  const page = await ctx.newPage(); const errors = [];
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text().slice(0, 120)); });
  await page.goto(lan + '/', { waitUntil: 'load' }); await page.waitForTimeout(8000); await dismiss(page);
  ok('mobile: no console errors', errors.length === 0, errors.slice(0, 2).join(' | '));
  // bridge 2.10.12: своя мобильная шапка (≡ · заголовок · +) слушает touch —
  // обычный click ящик не открывает, нужен tap; click оставлен запасным путём.
  const openDrawer = async () => {
    if (await page.evaluate(() => document.body.classList.contains('dsh-drawer-open'))) return;
    const burger = page.locator('.dsh-header-menu-btn').first();
    await burger.tap({ force: true }).catch(async () => { await burger.click({ force: true }); });
    await page.waitForTimeout(1000);
  };
  await openDrawer();
  ok('mobile: drawer opens', await page.evaluate(() => document.body.classList.contains('dsh-drawer-open')));
  const pb = page.locator('.dsh-power-btn').first();
  ok('mobile: sidebar power button', await pb.count() > 0 && await pb.isVisible());
  if (await pb.count()) {
    await pb.click(); await page.waitForTimeout(400);
    const r = await page.evaluate(() => { const p = document.querySelector('.dsh-power-pop'); if (!p) return null; const b = p.getBoundingClientRect(); return { l: b.left, r: b.right, w: innerWidth, bg: getComputedStyle(p).backgroundColor }; });
    ok('mobile: popover inside viewport, dark', !!r && r.l >= 0 && r.r <= r.w && r.bg === 'rgb(20, 26, 46)', JSON.stringify(r));
    await page.screenshot({ path: `${OUT}/m-power.png` });
    await page.locator('.dsh-power-pop button', { hasText: 'Cancel' }).click().catch(() => {});
  }
  // bridge 2.10.12: своя мобильная шапка (≡ · заголовок · +). Ящик открывается
  // ТОЛЬКО тапом (touch-события), click/dispatchEvent его не трогают; до тапа
  // боковая панель за пределами вьюпорта.
  await openDrawer(); // попап питания мог закрыть ящик
  await page.locator('.BlCpQa_triggerLabel, [class*="_triggerLabel"]', { hasText: 'Settings' }).first().click({ force: true }); await page.waitForTimeout(1500);
  for (const tab of ['General', 'Plugin Hub', 'Remote access']) {
    await page.locator('nav button', { hasText: tab }).first().click({ force: true }); await page.waitForTimeout(2500);
    const over = await page.evaluate(() => [...document.querySelectorAll('div[class*="_panel"] *')].filter(e => { const r = e.getBoundingClientRect(); const cs = getComputedStyle(e); return r.width > 0 && r.right > innerWidth + 2 && cs.opacity !== '0' && cs.visibility !== 'hidden' && !e.closest('[class*="_tabsRow"], [class*="_sortGroup"], [class*="_segGroup"]'); }).length);
    ok(`mobile: settings/${tab} no overflow`, over === 0, `overflowing=${over}`);
    await page.screenshot({ path: `${OUT}/m-settings-${tab.replace(/\s/g, '')}.png` });
  }
  ok('mobile: Remote access shows admin lock or tabs', await page.locator('text=/Unlock admin|Ops & monitoring/').count() > 0);
  await ctx.close();
}
// --- desktop via localhost (admin auto-unlock)
{
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  const page = await ctx.newPage();
  await page.goto(local, { waitUntil: 'load' }); await page.waitForTimeout(8000); await dismiss(page);
  ok('desktop: sidebar power button', await page.locator('.dsh-power-btn').count() > 0);
  await page.locator('button', { hasText: 'Settings' }).first().click({ force: true }); await page.waitForTimeout(1500);
  await page.locator('button', { hasText: 'Remote access' }).first().click({ force: true }); await page.waitForTimeout(3000);
  // Считаем китайский ТОЛЬКО в нашей части панели. Каталог плагинов показывает
  // рядом заметки к выпуску от авторов — у моста они по-китайски (2026-09-23:
  // «【v2.10.13】可靠性加固…»), и наивный подсчёт по всей панели давал ложный
  // провал. Блоки каталога и заметок исключаем по классу и по маркеру версии.
  const chinese = await page.evaluate(() => {
    const panel = document.querySelector('div[class*="_panel"]');
    if (panel === null) return 0;
    const copy = panel.cloneNode(true);
    for (const node of copy.querySelectorAll('*')) {
      const cls = (node.className || '').toString();
      const text = node.textContent || '';
      if (/hub|release|changelog|notes|update/i.test(cls) || /Highlights:|✨/.test(text)) node.remove();
    }
    return (copy.textContent || '').match(/[一-鿿]/g)?.length || 0;
  });
  ok('desktop: Remote access panel has no Chinese', chinese === 0, `cjk=${chinese}`);
  const pt = page.locator('button', { hasText: /^Power$/ }).first();
  ok('desktop: Power tab exists', await pt.count() > 0);
  if (await pt.count()) { await pt.click({ force: true }); await page.waitForTimeout(1500); ok('desktop: Power card', await page.locator('text=Stop DSH (keep Ubuntu)').count() > 0); await page.screenshot({ path: `${OUT}/d-power-tab.png` }); }
  await ctx.close();
}
await browser.close();
console.log(results.join('\n'));
process.exit(results.some(r => r.startsWith('FAIL')) ? 1 : 0);
