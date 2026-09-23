// better-sidebar: a file link FROM THE CHAT must open the same way as one from
// the explorer.
//
// WHY. The preview route `/sidebar/html/<sessionId>/<path>` builds the path out
// of URL segments and treats it as ABSOLUTE (lib/index.js:669 decodeHtmlUrl:
// `path = "/" + tail.join("/")`), and `htmlUrl(scope, path)` (lib/client.js:3832)
// passes the path through unchanged.
//
// From the sidebar explorer the path arrives absolute and everything works. From
// the conversation the host gives a path RELATIVE to the workspace ("cv.html",
// "out/shot.png"), the URL becomes `/sidebar/html/session-.../cv.html`, the
// server expands it to "/cv.html", the file ends up outside the workspace and the
// request answers 400. What the user sees: a link in the chat fails while the
// same file opens fine from the explorer.
//
// THE PATCH. `htmlUrl` completes a relative path with the session's working
// directory, using the very helper the plugin already uses elsewhere -
// `resolveSidebarPath(cwd, path)` (lib/client.js:3180). Absolute paths pass
// through untouched: the helper's first line returns them as they are. The
// neighbouring `/sidebar/file` route (images from the chat, downloads) has the
// same problem - it passes cwd as a separate parameter but the server still
// requires an absolute path (lib/index.js:295 requireAbsolute) - so it is
// completed as well.
//
// lib/client-editor.js is a separate editor chunk with no copy of
// resolveSidebarPath, so a small inline equivalent is injected there.
//
// Written through unlink: plugin files are hardlinks into the pnpm store.
import { readFileSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2] || `${process.env.HOME}/.dsh/profiles/web/node_modules/dsh-better-sidebar`;
const MARK = '/* dsh-local: relative path in chat links */';

// Where htmlUrl lives and what replaces it in each file: the main bundle has
// resolveSidebarPath, the editor chunk does not.
// The /sidebar/file route (chat images, downloads) also requires an absolute
// path (lib/index.js:295 requireAbsolute); its cwd parameter only bounds the
// workspace and is not used to complete the path, so a relative path from the
// chat answers 400 and the image never opens. Complete it the same way.
const FILE_URL_ANCHOR = '\t\t\tconst params = new URLSearchParams({\n\t\t\t\tsessionId: scope.sessionId,\n\t\t\t\tpath\n\t\t\t});\n';
const FILE_URL_PATCH = `\t\t\tconst params = new URLSearchParams({ ${MARK} // a path from the chat arrives relative
\t\t\t\tsessionId: scope.sessionId,
\t\t\t\tpath: resolveSidebarPath(scope.cwd, path)
\t\t\t});
`;

const targets = [
  {
    file: 'lib/client.js',
    anchor: '\t\tfunction htmlUrl(scope, path) {\n\t\t\treturn encodeHtmlUrl(scope.sessionId, path);\n\t\t}\n',
    patch: `\t\tfunction htmlUrl(scope, path) { ${MARK} // a path from the chat arrives relative
\t\t\treturn encodeHtmlUrl(scope.sessionId, resolveSidebarPath(scope.cwd, path));
\t\t}
`,
  },
  {
    file: 'lib/client-registry.js',
    anchor: '\t\tfunction htmlUrl(scope, path) {\n\t\t\treturn encodeHtmlUrl(scope.sessionId, path);\n\t\t}\n',
    patch: `\t\tfunction htmlUrl(scope, path) { ${MARK} // a path from the chat arrives relative
\t\t\treturn encodeHtmlUrl(scope.sessionId, resolveSidebarPath(scope.cwd, path));
\t\t}
`,
  },
  {
    file: 'lib/client-editor.js',
    anchor: '\tfunction htmlUrl(scope, path) {\n\t\treturn encodeHtmlUrl(scope.sessionId, path);\n\t}\n',
    patch: `\tfunction htmlUrl(scope, path) { ${MARK} // a path from the chat arrives relative
\t\tconst absolute = (() => {
\t\t\tif (/^([A-Za-z]:[\\\\/]|[\\\\/])/.test(path)) return path;
\t\t\tconst base = (scope.cwd ?? "").replace(/[\\\\/]+$/, "");
\t\t\tif (base === "") return path;
\t\t\treturn base + (base.includes("\\\\") ? "\\\\" : "/") + path;
\t\t})();
\t\treturn encodeHtmlUrl(scope.sessionId, absolute);
\t}
`,
  },
];

let touched = 0, already = 0, missing = 0;
for (const { file, anchor, patch } of targets) {
  const path = join(dir, file);
  if (!existsSync(path)) { missing++; continue; }
  let s = readFileSync(path, 'utf8');
  if (s.includes(MARK)) { already++; continue; }
  const n = s.split(anchor).length - 1;
  if (n !== 1) { console.error(`${file}: MATCH COUNT ${n} for the htmlUrl anchor`); process.exit(1); }
  s = s.replace(anchor, patch);
  // second anchor: only where fileUrl exists (the main bundle and the registry)
  const fileHits = s.split(FILE_URL_ANCHOR).length - 1;
  if (fileHits === 1) s = s.replace(FILE_URL_ANCHOR, FILE_URL_PATCH);
  else if (fileHits > 1) { console.error(`${file}: MATCH COUNT ${fileHits} for the fileUrl anchor`); process.exit(1); }
  rmSync(path, { force: true });
  writeFileSync(path, s);
  touched++;
}
console.log(`better-sidebar: relative paths from the chat - updated ${touched}, already patched ${already}`);
