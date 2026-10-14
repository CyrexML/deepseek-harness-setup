// better-sidebar 0.26+: the Files panel opens on the SESSION's folder again, not on
// the git repository that happens to contain it. Idempotent.
//
//   node patch-better-sidebar-session-root.mjs [plugin_dir]
//
// WHY. 0.26 roots the sidebar at `activeWorktreeRootOf(ctx, sessionId, base)`
// (lib/index.js): when the session cwd lies inside a git repository, the root
// becomes the repository top level -
//
//     const effectiveBase = pathUnderOf(base, canonicalTop) ? base : canonicalTop;
//
// (`pathUnderOf(base, target)` = "target is base or under it", so a cwd INSIDE
// the repository yields the top level). On this stand every project lives in
// ~/Harness_AI/projects/<name>, and ~/Harness_AI is itself a git repository
// (with projects/ in its .gitignore). Measured on the 0.2 test stand: a session
// with header cwd .../projects/Presentation got `session.cwd` = ~/Harness_AI, and
// Files listed .dsh/.git/backups/scripts... instead of the deck. 0.22 showed
// Presentation.
//
// THE PATCH. effectiveBase is the session cwd itself. The rest of 0.26's logic
// stays: a linked git worktree the agent actually worked in (read from the
// session's tool calls) still becomes the root, and the Git panel resolves its
// repository on its own (gitCwdOf -> repoRoot).
//
// Written through unlink: plugin files are hardlinks into the pnpm store.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2]
  || `${process.env.DSH_HOME ?? `${process.env.HOME}/.dsh`}/profiles/web/node_modules/dsh-better-sidebar`;
const file = join(dir, 'lib/index.js');
const MARK = '/* dsh-local: sidebar root is the session cwd */';

if (!existsSync(file)) { console.error(`no such file: ${file}`); process.exit(1); }
let s = readFileSync(file, 'utf8');
if (s.includes(MARK)) { console.log('better-sidebar: session root already patched'); process.exit(0); }

const ANCHOR = '\tconst effectiveBase = pathUnderOf(base, canonicalTop) ? base : canonicalTop;\n';
const n = s.split(ANCHOR).length - 1;
if (n !== 1) { console.error(`better-sidebar: MATCH COUNT ${n} for the effectiveBase line`); process.exit(1); }
s = s.replace(ANCHOR, `\tconst effectiveBase = base; ${MARK} // was: the enclosing repository's top level\n`);
rmSync(file, { force: true });
writeFileSync(file, s);
console.log('better-sidebar: sidebar root is the session cwd');
