// dsh-bridge: let the HOST's own directory picker run on the phone too. Idempotent.
//
//   node patch-picker-yield.mjs <plugin_dir>
//
// WHY. DSH 0.1.5+ ships an official directory picker and registers it into
// `conversation.hero.workspace.directoryFlow` and `sidebar.workspaces.directoryFlow`.
// The bridge registers its OWN flow into the same two slots, and DSH slots are
// shadow semantics - a plugin registration wins over the built-in regardless of
// priority. So the bridge steps aside only when it decides to:
//
//     shouldYieldToOfficialPicker = local && officialPicker
//
// `local` means a loopback page. On a phone it is false, so the bridge keeps the
// slots and tapping "Add workspace" opens the PLUGIN's drawer instead of DSH's
// own "Select Workspace Directory" dialog - the one with "New folder", which is
// what creating a project needs. The plugin's drawer has no such button.
//
// The DOM-level interception in patch-picker.mjs cannot win this: it hands the
// click back to the host, and the host then asks the slot - which is the plugin.
//
// WHAT THIS CHANGES. The bridge yields whenever the official picker exists, on a
// phone as much as on the computer.
//
// THE TRADE-OFF, which the plugin's own comment states: the host picker does not
// consult the bridge, so it does not enforce the bridge's admin password or its
// `local_only` directory policy. On this stand that gate is not lost - it moved
// in front of the button. patch-picker.mjs asks `listRemoteDirectories` before
// the picker opens and refuses on both "admin privileges required" and
// "local-machine admin only", so a phone still has to unlock admin first. Dropping
// THAT patch while keeping this one would remove the gate; they belong together.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || '.';
const file = join(dir, 'client/picker-yield.js');
const MARK = '/* dsh-bridge-en: picker yield on remote */';

// Plugin files are hardlinks into the pnpm store: writing in place would corrupt
// the store copy, so the file is unlinked first (new inode) and then written.
const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

let s = readFileSync(file, 'utf8');
if (s.includes(MARK)) { console.log('bridge: picker yield already patched'); process.exit(0); }

const ANCHOR = '  return Boolean(facts?.local) && Boolean(facts?.officialPicker);';
const n = s.split(ANCHOR).length - 1;
if (n !== 1) {
  console.error(`client/picker-yield.js: MATCH COUNT ${n} - the plugin changed, re-check before patching`);
  process.exit(1);
}
unlinkWrite(file, s.replace(ANCHOR,
  `  ${MARK} // the admin gate sits in front of the button (patch-picker.mjs), so remote may use the host picker too\n` +
  `  return Boolean(facts?.officialPicker);`));
console.log('bridge: picker yields to the host directory picker on remote too');
