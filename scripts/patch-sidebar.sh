#!/usr/bin/env bash
# Re-apply local fixes to dsh-better-sidebar after a plugin update.
#
# FIVE independent upstream defects block the HTML previewer for any page split
# into modules. They are sequential gates: fixing one only moves the failure to
# the next, which is why they were found one at a time and each fix looked like
# it "changed nothing".
#
#   GATE 1 - sandbox / opaque origin (NOT patched here; a setting, see below)
#     The previewer renders the page in a sandboxed iframe with no
#     allow-same-origin, so the document has an opaque origin. The core's trust
#     fence refuses `Origin: null` outright. The top-level navigation carries no
#     Origin and is allowed, so index.html renders - but every `<script src>`
#     subresource is answered 403 and the page is inert. A single-file page with
#     an inline <script> makes no subresource request, which is why splitting
#     into modules is what exposes this.
#     FIX: `htmlViewerNoSandbox: true` under dsh-better-sidebar in
#     ~/.dsh/settings.yaml. Not scripted: it is a security trade, not a bug -
#     unsandboxed, a previewed page runs with the GUI's own origin and can read
#     and write session files. The fence itself must NOT be relaxed: it is what
#     stops any website from reading workspace files over loopback.
#
#   GATE 5 - CSP `sandbox` re-imposes the sandbox (patched, server)
#     The preview response carries `content-security-policy: sandbox ...` with
#     no allow-same-origin. That directive forces an opaque origin on the
#     document REGARDLESS of the iframe's sandbox attribute, so gate 1's fix
#     could never work: the client dropped the attribute, this header put the
#     sandbox straight back, subresources still went out with Origin: null, and
#     the fence still answered 403. Diagnosed by an unsandboxed iframe whose
#     contentDocument was still cross-origin. Fixed by tying the directive to
#     the same htmlViewerNoSandbox preference that governs the attribute, AND
#     scoping it to trusted roots: allow-scripts plus allow-same-origin is
#     equivalent to no sandbox at all, so only files under
#     DSH_PREVIEW_TRUSTED_ROOTS (default ~/Harness_AI/projects) get it. Foreign
#     HTML - a downloaded page, a report built from web data - stays fully
#     sandboxed and never reaches the GUI origin.
#
#   GATE 2 - persistence.inspect (patched, server)
#     sessionCwdOf falls back to `persistence.inspect(sessionId)` when a session
#     is not attached. This harness core has no `inspect`; it exposes
#     stat/list/open/create. Every such request answered 500
#     "persistence.inspect is not a function". stat() carries the same header.
#
#   GATE 3 - MEDIA_TYPES has no .js (patched, server)
#     The preview route types responses from a table listing images, pdf and
#     html only; anything else becomes application/octet-stream. The same
#     response sets `x-content-type-options: nosniff`, so the browser REFUSES to
#     execute the script - silently, with no page error.
#
#   GATE 4 - the preview iframe never remounts (patched, client bundle)
#     The client store starts at SIDEBAR_PREFS_DEFAULTS, where
#     htmlViewerNoSandbox is false, and fills from settings.get asynchronously.
#     A restored preview therefore mounts SANDBOXED and its document loads
#     before the real prefs arrive; swapping the `sandbox` attribute afterwards
#     does nothing to an already-loaded document, and TextEditor's iframe has no
#     `key` to remount it (BrowserView's does). Net effect: the preview is
#     sandboxed on every load whatever the setting says, so subresources stay
#     403 - which is why turning the sandbox off appeared to change nothing.
#     Keying the iframe on the mode makes the arriving prefs remount it.
#
# Upstream files: profiles/web/node_modules/dsh-better-sidebar/
#   lib/index.js          - server, what actually runs
#   lib/client-editor.js  - client chunk served at /sidebar/bundle/editor.js
#   src/**                - patched too so a rebuild keeps the fixes
#
# Idempotent - safe to run repeatedly and after any plugin update.
set -uo pipefail

PKG="$HOME/.dsh/profiles/web/node_modules/dsh-better-sidebar"
LIB="$PKG/lib/index.js"
SRC="$PKG/src/index.ts"
CLIENT="$PKG/lib/client-editor.js"

[ -f "$LIB" ] || { echo "not found: $LIB"; exit 1; }
[ -f "$LIB.bak-orig" ] || cp "$LIB" "$LIB.bak-orig"
[ -f "$CLIENT.bak-orig" ] || cp "$CLIENT" "$CLIENT.bak-orig"

python3 - "$LIB" "$SRC" "$CLIENT" <<'PYEOF'
import io, os, sys

lib_path, src_path, client_path = sys.argv[1], sys.argv[2], sys.argv[3]
# pnpm держит файлы пакета хардлинками на store: запись по месту портит копию
# в store. Удаляем (новый inode), затем пишем.
def _write(path, text):
    os.unlink(path)
    io.open(path, 'w', encoding='utf-8').write(text)
changed = []

# ── server: lib/index.js ────────────────────────────────────────────────────
lib = io.open(lib_path, encoding='utf-8').read()

if '".js": "text/javascript"' not in lib:                      # GATE 3
    old = '\t".html": "text/html",\n\t".htm": "text/html"\n};'
    new = ('\t".html": "text/html",\n\t".htm": "text/html",\n'
           '\t".js": "text/javascript",\n\t".mjs": "text/javascript",\n'
           '\t".css": "text/css",\n\t".json": "application/json"\n};')
    if old not in lib:
        raise SystemExit('lib: MEDIA_TYPES table not found - upstream changed, patch by hand')
    lib = lib.replace(old, new, 1)
    changed.append('lib: MIME table (gate 3)')

old = '\t\tconst metaCwd = (await persistence.inspect(sessionId)).meta.cwd;'   # GATE 2
if old in lib:
    lib = lib.replace(old, '\t\tconst metaCwd = (await persistence.stat(sessionId))?.header?.cwd;', 1)
    changed.append('lib: persistence.stat (gate 2)')

if 'DSH_PREVIEW_TRUSTED_ROOTS' not in lib:                      # GATE 5
    T = '\t' * 5
    SB = '"sandbox allow-scripts allow-popups allow-downloads allow-modals; object-src \'none\'"'
    SO = '"sandbox allow-scripts allow-popups allow-downloads allow-modals allow-same-origin; object-src \'none\'"'
    old = T + '"content-security-policy": ' + SB + '\n'
    new = (T + '"content-security-policy": (() => {\n'
           + T + '\tif (settingsFace?.get()?.value?.htmlViewerNoSandbox !== true) return ' + SB + ';\n'
           + T + '\tconst roots = (process.env.DSH_PREVIEW_TRUSTED_ROOTS || ((process.env.HOME || "") + "/Harness_AI/projects")).split(":").filter(Boolean);\n'
           + T + '\tconst trusted = roots.some((r) => absolute === r || absolute.startsWith(r.endsWith("/") ? r : r + "/"));\n'
           + T + '\treturn trusted ? ' + SO + ' : ' + SB + ';\n'
           + T + '})()\n')
    if lib.count(old) != 1:
        raise SystemExit('lib: CSP header not found - upstream changed, patch by hand')
    lib = lib.replace(old, new, 1)
    changed.append('lib: CSP scoped to trusted roots (gate 5)')

_write(lib_path, lib)

# ── client chunk: lib/client-editor.js ──────────────────────────────────────
client = io.open(client_path, encoding='utf-8').read()

if 'htmlNoSandbox ? "ns" : "sb"' not in client:                # GATE 4
    tail = ('\t\t\t\treferrerPolicy: "no-referrer",\n'
            '\t\t\t\tallow: "",\n\t\t\t\ttitle: path\n\t\t\t})] }),')
    head = '\t\t\t\tsandbox: htmlNoSandbox ? void 0 : "allow-scripts allow-popups allow-downloads allow-modals",\n'
    old = head + tail
    new = old.replace('\t\t\t})] }),', '\t\t\t}, htmlNoSandbox ? "ns" : "sb")] }),')
    if client.count(old) != 1:
        raise SystemExit('client: preview iframe call site not found - upstream changed, patch by hand')
    client = client.replace(old, new, 1)
    _write(client_path, client)
    changed.append('client: iframe remount key (gate 4)')

# ── sources, so a rebuild keeps the fixes ───────────────────────────────────
try:
    src = io.open(src_path, encoding='utf-8').read()
except OSError:
    src = None

if src is not None:
    if "'.js': 'text/javascript'" not in src:
        old = "  '.html': 'text/html',\n  '.htm': 'text/html',\n}"
        new = ("  '.html': 'text/html',\n  '.htm': 'text/html',\n"
               "  '.js': 'text/javascript',\n  '.mjs': 'text/javascript',\n"
               "  '.css': 'text/css',\n  '.json': 'application/json',\n}")
        if old in src:
            src = src.replace(old, new, 1)
            changed.append('src: MIME table')
    old = "    const inspected = await persistence.inspect(sessionId)\n    const metaCwd = inspected.meta.cwd"
    if old in src:
        new = "    const inspected = await persistence.stat(sessionId)\n    const metaCwd = inspected?.header?.cwd"
        src = src.replace(old, new, 1)
        changed.append('src: persistence.stat')
    _write(src_path, src)

tsx_path = src_path.replace('/index.ts', '/client/TextEditor.tsx')
try:
    tsx = io.open(tsx_path, encoding='utf-8').read()
except OSError:
    tsx = None

if tsx is not None and "key={htmlNoSandbox ? 'ns' : 'sb'}" not in tsx:
    old = "          <iframe\n            className={css.editorHtml}"
    if old in tsx:
        new = "          <iframe\n            key={htmlNoSandbox ? 'ns' : 'sb'}\n            className={css.editorHtml}"
        tsx = tsx.replace(old, new, 1)
        _write(tsx_path, tsx)
        changed.append('src: TextEditor iframe key')

print('\n'.join('  patched ' + c for c in changed) if changed else '  уже пропатчено, изменений нет')
PYEOF

node --check "$LIB" >/dev/null 2>&1 \
  && echo "  lib/index.js: синтаксис OK" \
  || echo "  ВНИМАНИЕ: lib/index.js не парсится, откат: cp $LIB.bak-orig $LIB"
node --check "$CLIENT" >/dev/null 2>&1 \
  && echo "  client-editor.js: синтаксис OK" \
  || echo "  ВНИМАНИЕ: client-editor.js не парсится, откат: cp $CLIENT.bak-orig $CLIENT"

cat <<'EOF'

Дальше:
  1. htmlViewerNoSandbox: true под dsh-better-sidebar в ~/.dsh/settings.yaml
     (gate 1 - это настройка, не баг; см. шапку про цену).
  2. Перезапустить хост (серверные правки) - клиентский чанк читается с диска
     на каждый запрос и отдаётся с no-cache + ETag, перезапуска не требует.
  3. Ctrl+Shift+R на странице интерфейса, чтобы забрать новый бандл.
  4. Проверить: scripts/check-sidebar-preview.sh
EOF
