// Use the DSH host's own directory picker ("Add workspace" dialog with New folder / Show hidden / Edit path)
// on remote/mobile too, instead of dsh-bridge's replacement modal. Set USE_NATIVE_PICKER=false to keep
// bridge's modal. Idempotent. Usage: node patch-picker.mjs <plugin_dir>
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
// Плагины лежат в pnpm-store хардлинками: запись «по месту» испортила бы копию в store,
// поэтому файл сначала удаляется (новый inode), потом пишется.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

import { join } from 'node:path';
const USE_NATIVE_PICKER = true;
const dir = process.argv[2] || '.';
const path = join(dir, 'client/index.js');
let s = readFileSync(path, 'utf8');
const ORIG = `    if (isLocalEnvironment()) return; // 本机电脑环境不拦截，使用系统原生文件夹对话框`;
const PATCHED = `    if (isLocalEnvironment()) return; // 本机电脑环境不拦截，使用系统原生文件夹对话框
    // dsh-bridge-en: with the host's own picker (window.__dshBridgeNativePicker !== false) the handler below only closes the drawer`;
const OPEN = `    if (isAddWorkspace) {
      e.preventDefault();
      e.stopPropagation();
      e.stopImmediatePropagation();

      if (typeof window.__dshOpenRemoteWorkspaceModal === 'function') {
        window.__dshOpenRemoteWorkspaceModal();
      }
    }`;
const OPEN_PATCHED = `    if (isAddWorkspace) {
      if (window.__dshBridgeNativePicker !== false) { // dsh-bridge-en: host picker, gated by the bridge admin password
        document.body.classList.remove('dsh-drawer-open');
        if (btn.dataset.dshAdminOk === '1') { delete btn.dataset.dshAdminOk; return; } // re-dispatched after verification
        e.preventDefault(); e.stopPropagation(); e.stopImmediatePropagation();
        ensureAdminForPicker(btn);
        return;
      }
      e.preventDefault();
      e.stopPropagation();
      e.stopImmediatePropagation();

      if (typeof window.__dshOpenRemoteWorkspaceModal === 'function') {
        window.__dshOpenRemoteWorkspaceModal();
      }
    }`;
if (!USE_NATIVE_PICKER) { console.log('client/index.js: native picker patch disabled (USE_NATIVE_PICKER=false)'); process.exit(0); }
if (s.includes(PATCHED) && s.includes('window.__dshBridgeNativePicker === false) // dsh-bridge-en') && s.includes('const ensureAdminForPicker = ')) { console.log('client/index.js: native picker patch already present'); process.exit(0); }
const n = s.split(ORIG).length - 1;
if (n !== 1) { console.error(`client/index.js: MATCH COUNT ${n} for picker anchor`); process.exit(1); }
s = s.replace(ORIG, PATCHED);
const k = s.split(OPEN).length - 1;
if (k !== 1) { console.error(`client/index.js: MATCH COUNT ${k} for open anchor`); process.exit(1); }
s = s.replace(OPEN, OPEN_PATCHED);
// admin gate helper (lives in setupMobileExperience scope: rpcCall / unlockAdmin / getAdminToken / BRIDGE_ENDPOINTS)
const GATE_ANCHOR = `  // 5. 拦截原生的「添加工作区 / 打开文件夹」操作`;
const GATE = readFileSync(new URL('picker-gate.js', import.meta.url), 'utf8') + GATE_ANCHOR;
const g = s.split(GATE_ANCHOR).length - 1;
if (g !== 1) { console.error(`client/index.js: MATCH COUNT ${g} for gate anchor`); process.exit(1); }
s = s.replace(GATE_ANCHOR, GATE);
// also skip bridge's directoryFlow slot registration (priority -10 overrides the host's browse picker)
const SLOT = `  ctx.slots.inject('conversation.hero.workspace.directoryFlow', () =>
    ctx.slots.inject('sidebar.workspaces.directoryFlow', function* () {
      yield ctx.slots.register(
        {
          name: 'conversation.hero.workspace.directoryFlow',
          priority: -10,`;
const SLOT_PATCHED = `  if (typeof window !== 'undefined' && window.__dshBridgeNativePicker === false) // dsh-bridge-en: keep the host's own picker
` + SLOT;
// С 2.10.13 мост делает это сам: в регистрации слота появился его собственный
// отказ в пользу родного выбора папки (`shouldYieldToOfficialPicker`). Тогда
// наша правка не нужна — и якорь всё равно не совпадёт, потому что между
// строками вставился новый код. Проверяем по имени функции, а не по версии
// пакета: так патч переживёт и переименование версии, и бэкпорт.
const UPSTREAM_GUARD = 'shouldYieldToOfficialPicker';
const m = s.split(SLOT).length - 1;
if (s.includes(UPSTREAM_GUARD)) {
  console.log('client/index.js: slot patch skipped — the plugin yields to the host picker itself');
} else if (m !== 1) {
  console.error(`client/index.js: MATCH COUNT ${m} for slot anchor`); process.exit(1);
} else {
  s = s.replace(SLOT, SLOT_PATCHED);
}
unlinkWrite(path, s);
console.log('client/index.js: native picker patch applied (click interception + slot registration)');
