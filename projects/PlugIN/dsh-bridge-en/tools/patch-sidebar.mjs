// Fix dsh-better-sidebar on mobile (dsh-bridge hides its toggle cluster and gates the panel behind
// body.dsh-workbench-open, which is only set for some clicks). Idempotent: skips edits already present.
// Usage: node patch-sidebar.mjs <plugin_dir>
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
// Плагины лежат в pnpm-store хардлинками: запись «по месту» испортила бы копию в store,
// поэтому файл сначала удаляется (новый inode), потом пишется.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

import { join } from 'node:path';
const dir = process.argv[2] || '.';
const MARK = '/* dsh-bridge-en: better-sidebar mobile fix */';

function patch(file, edits) {
  const path = join(dir, file);
  let s = readFileSync(path, 'utf8');
  let applied = 0, skipped = 0;
  for (const [a, b] of edits) {
    if (s.includes(b)) { skipped++; continue; }
    const n = s.split(a).length - 1;
    if (n !== 1) { console.error(`${file}: MATCH COUNT ${n} for ${JSON.stringify(a.slice(0, 70))}`); process.exit(1); }
    s = s.replace(a, b); applied++;
  }
  unlinkWrite(path, s);
  console.log(`${file}: sidebar patch applied ${applied}, already present ${skipped}`);
}

// ---------------- client/index.js ----------------
const HELPERS = `${MARK}
  // better-sidebar (dsh-better-sidebar) integration: its toggle cluster is hidden on mobile by our CSS,
  // so drive it programmatically. The right-panel toggle is the LAST button of the cluster.
  const sidebarToggleBtn = () => document.querySelector('[data-dsh-toggle-cluster] button:last-of-type, div[class*="toggleCluster"] button:last-of-type');
  const sidebarOpenPanels = () => document.querySelectorAll('div[class*="nArs4W_panel"]:not([class*="panelHidden"]), div[class*="workbench_panel"]:not([class*="panelHidden"])');
  const closeSidebarPanel = () => {
    if (!sidebarOpenPanels().length) return;
    const t = sidebarToggleBtn();
    if (t && t.getAttribute('aria-disabled') !== 'true') t.click();
    else sidebarOpenPanels().forEach((p) => p.classList.add('nArs4W_panelHidden'));
    document.body.classList.remove('dsh-workbench-open');
  };
  const toggleSidebarPanel = () => {
    const t = sidebarToggleBtn();
    if (t && t.getAttribute('aria-disabled') !== 'true') { t.click(); return; }
    document.body.classList.toggle('dsh-workbench-open');
  };
  // Touch fallback for better-sidebar tabs: some mobile WebKit builds resolve a tap on the scrollable
  // tab strip to the strip itself and never deliver a click to the tab. Find the tab under the touch
  // point geometrically and activate it if no native click follows shortly.
  (() => {
    if (window.__dshBridgeTabTouchShim) return;
    window.__dshBridgeTabTouchShim = true;
    const isTab = (el) => el instanceof HTMLElement && /nArs4W_tab(\s|$)/.test(el.className) && !/tabBar|tabList/.test(el.className);
    let start = null; let pending = null;
    document.addEventListener('click', (e) => { if (pending && e.target instanceof Node && pending.contains(e.target)) pending = null; }, true);
    document.addEventListener('touchstart', (e) => { const t = e.touches[0]; start = t ? { x: t.clientX, y: t.clientY, at: Date.now() } : null; }, { capture: true, passive: true });
    document.addEventListener('touchend', (e) => {
      if (window.innerWidth > 768 || !start) return;
      const t = e.changedTouches[0]; if (!t) return;
      if (Math.hypot(t.clientX - start.x, t.clientY - start.y) > 12 || Date.now() - start.at > 600) return;
      if (e.target instanceof Element && e.target.closest('button[class*="tabClose"], button[class*="tabBarPlus"]')) return;
      let tab = e.target instanceof Element ? e.target.closest('div[class*="nArs4W_tab"]') : null;
      if (!isTab(tab)) {
        tab = [...document.querySelectorAll('div[class*="nArs4W_tab"]')].find((el) => isTab(el) && (() => { const r = el.getBoundingClientRect(); return t.clientX >= r.left && t.clientX <= r.right && t.clientY >= r.top && t.clientY <= r.bottom; })()) || null;
      }
      if (!tab) return;
      pending = tab;
      setTimeout(() => { if (pending === tab) { pending = null; tab.click(); } }, 350);
    }, { capture: true, passive: true });
  })();
`;

patch('client/index.js', [
  // helpers right after the mobile styles are injected
  [`function setupMobileExperience(rpcCall, ctx) {
  if (typeof document === 'undefined' || typeof window === 'undefined') return;
  injectMobileStyles();
`, `function setupMobileExperience(rpcCall, ctx) {
  if (typeof document === 'undefined' || typeof window === 'undefined') return;
  injectMobileStyles();
${HELPERS}`],
  // title click: close via the real toggle
  [`    titleEl.onclick = () => {
      const openPanels = document.querySelectorAll('div[class*="nArs4W_panel"]:not([class*="panelHidden"]), div[class*="workbench_panel"]:not([class*="panelHidden"])');
      openPanels.forEach((p) => p.classList.add('nArs4W_panelHidden'));
    };`, `    titleEl.onclick = () => { closeSidebarPanel(); };`],
  // new-session click: close via the real toggle
  [`    rightBtn.onclick = () => {
      const openPanels = document.querySelectorAll('div[class*="nArs4W_panel"]:not([class*="panelHidden"]), div[class*="workbench_panel"]:not([class*="panelHidden"])');
      openPanels.forEach((p) => p.classList.add('nArs4W_panelHidden'));
      const dshNewBtn`, `    rightBtn.onclick = () => {
      closeSidebarPanel();
      const dshNewBtn`],
  // header: sidebar button between the title and (+)
  [`    header.appendChild(leftBtn);
    header.appendChild(titleEl);
    header.appendChild(rightBtn);`, `    // Sidebar (workbench) toggle — drives dsh-better-sidebar's hidden toggle cluster
    const sideBtn = document.createElement('button');
    sideBtn.className = 'dsh-header-sidebar-btn';
    sideBtn.title = 'Toggle sidebar';
    sideBtn.setAttribute('aria-label', 'Toggle sidebar');
    sideBtn.innerHTML = \`
      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
        <rect x="3" y="4" width="18" height="16" rx="2.5"></rect>
        <line x1="14.5" y1="4" x2="14.5" y2="20"></line>
      </svg>
    \`;
    sideBtn.onclick = (e) => { e.stopPropagation(); toggleSidebarPanel(); };

    header.appendChild(leftBtn);
    header.appendChild(titleEl);
    header.appendChild(sideBtn);
    header.appendChild(rightBtn);`],
  // session switch: close via the real toggle
  [`        document.body.classList.remove('dsh-workbench-open');
        const openPanels = document.querySelectorAll('div[class*="nArs4W_panel"]:not([class*="panelHidden"]), div[class*="workbench_panel"]:not([class*="panelHidden"])');
        openPanels.forEach((p) => p.classList.add('nArs4W_panelHidden'));
      }
    });`, `        closeSidebarPanel();
      }
    });`],
  // observer: keep body.dsh-workbench-open in sync with the panel's real state
  [`    const panels = document.querySelectorAll('div[class*="nArs4W_panel"]:not([class*="panelHidden"]), div[class*="workbench_panel"]:not([class*="panelHidden"])');
    panels.forEach((p) => {`, `    const panels = document.querySelectorAll('div[class*="nArs4W_panel"]:not([class*="panelHidden"]), div[class*="workbench_panel"]:not([class*="panelHidden"])');
    // sync: a panel opened by better-sidebar itself (file click, agent open) must become visible
    document.body.classList.toggle('dsh-workbench-open', panels.length > 0);
    document.body.classList.toggle('dsh-sidebar-panel-open', panels.length > 0);
    panels.forEach((p) => {`],
  // "Back to chat" button: not mounted — the header sidebar button opens AND closes the panel,
  // and the in-tab-strip button ate space from the tabs.
  [`      const bar = p.querySelector('div[class*="tabBar"], div[class*="nArs4W_tabBar"]');
      if (bar && !bar.querySelector('.dsh-mobile-panel-close-btn')) {`, `      const bar = p.querySelector('div[class*="tabBar"], div[class*="nArs4W_tabBar"]');
      if (false && bar && !bar.querySelector('.dsh-mobile-panel-close-btn')) { // disabled: header sidebar button replaces it`],
]);

// ---------------- client/mobile-styles.js ----------------
patch('client/mobile-styles.js', [
  [`      .dsh-header-new-btn:active {
        opacity: 0.6;
      }
`, `      .dsh-header-new-btn:active {
        opacity: 0.6;
      }

      ${MARK}
      .dsh-header-sidebar-btn {
        width: 40px;
        height: 40px;
        border-radius: 50%;
        border: none;
        background: transparent;
        color: var(--dsw-alias-label-primary, #111827);
        display: inline-flex;
        align-items: center;
        justify-content: center;
        cursor: pointer;
        padding: 0;
        transition: opacity 0.15s;
        pointer-events: auto !important;
      }
      .dsh-header-sidebar-btn:active { opacity: 0.6; }
      body.dsh-sidebar-panel-open .dsh-header-sidebar-btn { color: #2563eb; }
`],
  // The pill-tab rule above uses [class*="nArs4W_tab"], which ALSO matches nArs4W_tabBar / nArs4W_tabList
  // and (being declared later) clamps the whole strip to max-width:170px. Re-assert the strip/list sizing
  // after it so the tab strip spans the full panel width.
  [`      div[class*="nArs4W_tabActive"],
      div[class*="workbench_tabActive"] {`, `      ${MARK}
      div[class*="nArs4W_tabBar"],
      div[class*="workbench_tabBar"] {
        flex: none !important;
        width: 100% !important;
        max-width: none !important;
        min-width: 0 !important;
        min-height: 40px !important;
        height: 40px !important;
        padding: 0 8px !important;
        border-radius: 0 !important;
        background: var(--dsw-alias-bg-layer-1, #ffffff) !important;
        box-shadow: none !important;
        justify-content: space-between !important;
      }
      div[class*="nArs4W_tabList"] {
        flex: 1 1 auto !important;
        width: auto !important;
        max-width: none !important;
        min-width: 0 !important;
        height: auto !important;
        padding: 0 !important;
        border-radius: 0 !important;
        background: transparent !important;
        box-shadow: none !important;
        justify-content: flex-start !important;
      }
      /* no blue tap flash on the tab strip / tabs / panel toggle */
      div[class*="nArs4W_tabBar"],
      div[class*="nArs4W_tabBar"] *,
      div[class*="nArs4W_tab"],
      .dsh-header-sidebar-btn {
        -webkit-tap-highlight-color: transparent !important;
        -webkit-touch-callout: none !important;
      }

      div[class*="nArs4W_tabActive"],
      div[class*="workbench_tabActive"] {`],
]);
