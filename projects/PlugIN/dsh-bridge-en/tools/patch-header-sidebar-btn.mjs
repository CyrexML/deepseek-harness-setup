// bridge: remove the added sidebar button from the mobile header.
//
// WHY. The `dsh-header-sidebar-btn` button (tools/patch-sidebar.mjs) appeared when
// better-sidebar drew the panel itself and its own toggle was hidden on the
// phone. In DSH 0.1.6 the right panel is drawn by the native `ui-sidebar-right`
// with its own toggle, so this button only duplicates it.
//
// The patch keeps the `toggleSidebarPanel`/`closeSidebarPanel` helpers (the header
// and session switching call them) and only stops inserting the button into the
// header: instead of `header.appendChild(sideBtn)` there is an empty line with the
// marker. The button is never created and its CSS stays as harmless dead code.
//
// Written through unlink: plugin files are hardlinks into the pnpm store.
// Afterwards bridge-rebuild-client.sh rebuilds client/client.js, which is what
// the browser gets.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || `${process.env.HOME}/.dsh/profiles/web/node_modules/@wenbin_wb/dsh-bridge`;
const MARK = '/* dsh-bridge-en: header sidebar button removed */';
const file = join(dir, 'client/index.js');
if (!existsSync(file)) { console.error(`no such file: ${file}`); process.exit(1); }

let s = readFileSync(file, 'utf8');
if (s.includes(MARK)) { console.log('bridge: the sidebar button is already gone'); process.exit(0); }

// 1. do not create the button: the whole block from the comment to onclick
const CREATE_START = '    // Sidebar (workbench) toggle';
const CREATE_END = '    sideBtn.onclick = (e) => { e.stopPropagation(); toggleSidebarPanel(); };\n';
const start = s.indexOf(CREATE_START);
const end = s.indexOf(CREATE_END);
if (start === -1 || end === -1 || end < start) { console.error('the button-creation anchor was not found'); process.exit(1); }
s = s.slice(0, start) + `    ${MARK} // the native ui-sidebar-right (0.1.6) has its own toggle\n` + s.slice(end + CREATE_END.length);

// 2. do not insert it into the header
const APPEND = '    header.appendChild(sideBtn);\n';
const n = s.split(APPEND).length - 1;
if (n !== 1) { console.error(`MATCH COUNT ${n} for header.appendChild(sideBtn)`); process.exit(1); }
s = s.replace(APPEND, '');

rmSync(file, { force: true });
writeFileSync(file, s);
console.log('bridge: sidebar button removed from the mobile header');
