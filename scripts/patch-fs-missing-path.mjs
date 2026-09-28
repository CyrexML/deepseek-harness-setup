// A missing path must not be reported as an unread file. Idempotent.
//   node patch-fs-missing-path.mjs [dsh_root]
//
// Why. The observation guard fires before anything looks at the disk, so a
// write or edit aimed at a path that does not exist comes back as
// FS_NOT_OBSERVED, and remediateFsError renders it
// (packages/fs/tool-fs/src/error.ts:25):
//
//   cannot modify "<home>/Hess_A": file has not been read - read the file,
//   then retry
//
// The model is told to read a file that cannot be read, so the message carries
// no way to diagnose the real fault. Session e1955cfc (2026-09-28, turn 2):
// the model mistyped a 70-character absolute path once, noticed it by itself
// ("опечатка в пути"), fixed it - and then repeated the SAME mangled path five
// more times over three minutes, copying it back out of its own failed calls.
// Five of the turn's eleven tool errors were that one path.
//
// What this changes. Only the message, and only when the resolved display path
// does not exist: the code stays FS_NOT_OBSERVED so any machine routing on it
// is untouched, and an existing-but-unread file still gets the original
// read-the-file remedy. File creation is unaffected: fs-local raises
// FS_NOT_OBSERVED for a write only when the target already exists
// ("cannot overwrite existing ... without reading it first",
// fs-local/src/index.ts:197).
//
// Scope. existsSync talks to the host filesystem directly, which is right for
// this stand (ctx.fs is fs-local) but would be wrong behind a remote backend
// such as e2b, where the path lives on the other side of the seam. The check is
// fail-safe: anything unexpected leaves the original message in place.
//
// displayPath is always absolute - resolveLocalTarget builds it through
// localDisplayPath (fs-local/src/fsio.ts:145) before any existence check - so
// the lookup never depends on the server's own working directory.
//
// Written through unlink: package files may be hardlinks into the pnpm store.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';

const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

const root = process.argv[2] || `${process.env.HOME}/tools/deepseek-harness`;
const path = join(root, 'packages/fs/tool-fs/lib/index.js');
const MARK = 'dsh-local: missing path before unread';

let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) { console.log('tool-fs/lib/index.js: missing-path diagnostic already present'); process.exit(0); }

// 1. node:fs is not among the module's imports; add it next to node:path.
const IMPORT_ANCHOR = 'import { basename, extname } from "node:path";\n';
if (!s.includes(IMPORT_ANCHOR)) { console.error('anchor not found: node:path import'); process.exit(1); }
if (!s.includes('from "node:fs"')) {
  s = s.replace(IMPORT_ANCHOR, `${IMPORT_ANCHOR}import { existsSync as __dshExistsSync } from "node:fs";\n`);
}

// 2. The FS_NOT_OBSERVED branch of remediateFsError.
const OLD = 'if (error.code === "FS_NOT_OBSERVED") return new FsError(`cannot modify "${displayPath}": file has not been read — read the file, then retry`, error.code, { cause: error });';
if (!s.includes(OLD)) { console.error('anchor not found: FS_NOT_OBSERVED branch'); process.exit(1); }

const NEW = `if (error.code === "FS_NOT_OBSERVED") return new FsError(__dshPathMissing(displayPath) /* ${MARK} */
		? \`cannot modify "\${displayPath}": no such file — check the path, then retry\`
		: \`cannot modify "\${displayPath}": file has not been read — read the file, then retry\`, error.code, { cause: error });`;
s = s.replace(OLD, NEW);

// 3. The helper, right before the function that uses it.
const FN_ANCHOR = 'function remediateFsError(error, displayPath) {';
if (!s.includes(FN_ANCHOR)) { console.error('anchor not found: remediateFsError'); process.exit(1); }
const HELPER = `/** True only when the absolute display path is known to be absent; any doubt keeps the original message. ${MARK} */
function __dshPathMissing(displayPath) {
	try {
		return typeof displayPath === "string" && displayPath.startsWith("/") && !__dshExistsSync(displayPath);
	} catch {
		return false;
	}
}
`;
s = s.replace(FN_ANCHOR, `${HELPER}${FN_ANCHOR}`);

unlinkWrite(path, s);
console.log('tool-fs/lib/index.js: missing-path diagnostic applied');
