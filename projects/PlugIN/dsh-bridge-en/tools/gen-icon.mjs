// Build the DSH whale app icon (2026-09-14): tools/assets/pwa-icon.svg + PNG 512/192/180.
// usage: LD_LIBRARY_PATH=... node gen-icon.mjs   (needs playwright chromium from the harness checkout)
// Whale path = ui-primitives FishLogo (the same mark as the splash); DeepSeek blue on the splash's
// dark gradient; whale kept inside the central ~58% so a maskable (circle) crop never clips it.
import { readFileSync, writeFileSync } from 'node:fs';
const DSH_ROOT = process.env.DSH_ROOT ?? `${process.env.HOME}/tools/deepseek-harness`;
// Playwright sits in the pnpm store under a versioned name, so the path is
// SEARCHED for: a harness update changes the version. Not the newest one is taken
// but the one whose browsers are actually downloaded (~/.cache/ms-playwright) -
// the store may hold an alpha with no browsers, and launching then fails with
// "Executable doesn't exist".
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
if (__pw === undefined) throw new Error(`playwright not found in ${__pnpm}`);
const __pwEntry = `${__pnpm}/${__pw}/node_modules/playwright/index.mjs`;
const { chromium } = await import(__pwEntry);
const OUT = new URL('./assets/', import.meta.url).pathname;
const FISH = readFileSync(`${DSH_ROOT}/packages/client/ui-primitives/src/FishLogo.tsx`, 'utf8');
const FISH_PATH = /FISH_LOGO_PATH = '([^']+)'/.exec(FISH)?.[1];
const FISH_VB = /width: ([\d.]+), height: ([\d.]+)/.exec(FISH);
if (!FISH_PATH || !FISH_VB) { console.error('FishLogo.tsx: whale path not found'); process.exit(1); }
const vw = +FISH_VB[1], vh = +FISH_VB[2];
const W = 300, s = W / vw, H = vh * s;
const tx = (512 - W) / 2, ty = (512 - H) / 2;
const svg = (rounded) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
  <defs><radialGradient id="g" cx="50%" cy="0%" r="110%"><stop offset="0%" stop-color="#1b2340"/><stop offset="45%" stop-color="#141a2e"/><stop offset="100%" stop-color="#0f1117"/></radialGradient></defs>
  <rect width="512" height="512" rx="${rounded ? 112 : 0}" fill="url(#g)"/>
  <g transform="translate(${tx.toFixed(2)} ${ty.toFixed(2)}) scale(${s.toFixed(4)})"><path d="${FISH_PATH}" fill="#4d6bfe"/></g>
</svg>`;
writeFileSync(OUT + 'pwa-icon.svg', svg(true));
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 512, height: 512 }, deviceScaleFactor: 1 });
for (const [name, size, rounded] of [['pwa-icon-512.png', 512, false], ['pwa-icon-192.png', 192, false], ['apple-touch-icon.png', 180, false]]) {
  await page.setViewportSize({ width: size, height: size });
  await page.setContent(`<style>html,body{margin:0;background:transparent}svg{display:block;width:${size}px;height:${size}px}</style>${svg(rounded)}`);
  await page.screenshot({ path: OUT + name, omitBackground: true });
  console.log(name);
}
await browser.close();
