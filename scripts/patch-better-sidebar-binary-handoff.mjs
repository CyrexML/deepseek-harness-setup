// better-sidebar: hand PDFs and office files to whoever can actually render them.
//
// WHY. The plugin registers its `editor` type for EVERY file address
// (lib/client.js:17047) in the "extension" priority band. The native right
// sidebar's tab registry picks the best candidate and skips those whose `canOpen`
// returned false (packages/client/ui-sidebar-right/src/client/tab-registry.ts:353).
// While the plugin agrees to open everything it also takes .pdf and .xlsx - which
// it cannot draw, showing "This file type cannot be previewed / Download to view".
//
// WHAT THE PATCH DOES. `canOpen` declines the extensions the stand has a real
// viewer for:
//   * pdf    -> the native `ui-sidebar-documentpreview`: pdf.js draws pages into
//               a <canvas>, which also works in a mobile browser where an iframe
//               with a blob PDF just downloads the file on Android;
//   * office -> the dsh-univer-office plugin (an interactive sheet/document), or
//               the native office viewer when it is absent.
//
// HTML, markdown, images, code and everything else still open in the plugin - its
// sandbox setting is what multi-page apps need.
//
// Written through unlink: plugin files are hardlinks into the pnpm store.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || `${process.env.HOME}/.dsh/profiles/web/node_modules/dsh-better-sidebar`;
const MARK = '/* dsh-local: binary handoff */';
const ANCHOR = '\t\t\t\t\t\t\tcanOpen: (address) => parseFileAddress(address) !== void 0\n';
const PATCH = `\t\t\t\t\t\t\tcanOpen: (address) => { ${MARK} // pdf -> the host's pdf.js, office -> univer or the office viewer
\t\t\t\t\t\t\t\tconst parsed = parseFileAddress(address);
\t\t\t\t\t\t\t\tif (parsed === void 0) return false;
\t\t\t\t\t\t\t\treturn !/\\.(pdf|xlsx?|xlsm|xlsb|docx?|pptx?|odt|ods|odp)$/i.test(parsed.path ?? "");
\t\t\t\t\t\t\t}
`;

const files = ['lib/client.js', 'lib/client-registry.js'].filter(f => existsSync(join(dir, f)));
if (files.length === 0) { console.error(`no build files in ${dir}`); process.exit(1); }

let touched = 0, already = 0;
for (const rel of files) {
  const path = join(dir, rel);
  let s = readFileSync(path, 'utf8');
  if (s.includes(MARK)) { already++; continue; }
  const n = s.split(ANCHOR).length - 1;
  if (n !== 1) { console.error(`${rel}: MATCH COUNT ${n} for the canOpen anchor`); process.exit(1); }
  s = s.replace(ANCHOR, PATCH);
  rmSync(path, { force: true });
  writeFileSync(path, s);
  touched++;
}
console.log(`better-sidebar: binary handoff - updated ${touched}, already patched ${already} (files: ${files.length})`);
