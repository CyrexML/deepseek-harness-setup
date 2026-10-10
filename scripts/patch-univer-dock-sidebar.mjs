// dsh-univer-office: edit in the host's right sidebar, not in a floating window.
// Idempotent.
//
//   node patch-univer-dock-sidebar.mjs [plugin_dir]
//
// WHY. While a turn edits a `.univer` file the plugin opens its own window: a
// `createPortal` into `document.body` of `.uvf_root` (`position:fixed; inset:0;
// z-index:1200`) holding `.uvf_win` (`position:fixed`, draggable, resizable).
// It floats over the conversation, attached to nothing, and the in-flow review
// card only appears once the turn is over - which is exactly how the user
// described it: a window hanging in the air, then something inserted into the
// chat.
//
// WHY NOT CSS. The obvious fix is to pin `.uvf_win` to the right half and pull
// the app shell's right edge in to match. Measured on the live page: that
// moves the box but not the conversation. The composer keeps its width and is
// clipped.
//
//     real browser resize to 720px   composer 774 -> 681, repositioned
//     shrinking the shell to 720px   composer 774 -> 774, clipped
//
// The conversation column sizes itself from the viewport, not from its
// container, and no stylesheet can make a page believe the viewport is
// narrower.
//
// WHAT THIS DOES INSTEAD. The host already has the mechanism, and the plugin is
// already wired into it. `registerUniverSidebarTab` registers a right-sidebar
// tab type for `*.univer` (kind `univer`, patterns `["*.univer"]`), and the
// host's own right sidebar DOES reflow the chat - measured, composer 774 -> 473
// when it opens. So a file that would have popped a floating window is instead
// opened in that tab through `sidebarRight.openResource(address, {kind})`, the
// same call `ui-subagent` uses for its chat-aside.
//
// The result is the arrangement the user asked for - a panel on the right with
// the conversation beside it - built from the host's own layout rather than
// from `!important` overrides: native width, native resize, native collapse.
//
// THE FALLBACK IS THE POINT. `openInSidebar` returns false when the host
// exposes no `sidebarRight`, when the address is refused, or when the call
// throws. Only files it accepted are removed from the floating set, so a host
// without the service keeps exactly today's behaviour and the live preview is
// never simply lost. The `livePreview` preference still gates the whole thing.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';

const dir = process.argv[2]
  || `${process.env.DSH_HOME ?? `${process.env.HOME}/.dsh`}/profiles/web/node_modules/dsh-univer-office`;
const file = join(dir, 'lib/client.js');

const MARK = '/* dsh-local: univer edits dock into the host right sidebar */';

let s = readFileSync(file, 'utf8');
if (s.includes(MARK)) { console.log('univer: already docked to the sidebar'); process.exit(0); }

const EDITS = [
  // 1. The opener. Built next to the dock registration so it closes over `ctx`.
  //    The address format is the host's own `sessionFileAddress`:
  //    `dsh-resource://file/session/<sessionId>/<path>`, each segment
  //    component-encoded with `:` kept literal for drive letters, backslashes
  //    normalised and leading `./` dropped.
  [
    `      ctx.effect(
        () => ctx.slots.inject(
          "conversation.input.dock",
          () => ctx.slots.register(
            {
              name: "conversation.input.dock",
              id: "univer-dock",
              order: 400,
              locale: UNIVER_LOCALE_NAMESPACE,
              inject: () => ({ getViewerLocale, preferences })
            },
            UniverDock
          )
        ),
        "univer: worktree dock"
      );`,
    `      ${MARK}
      const encodeAddressSegment = (segment) => encodeURIComponent(segment).replace(/%3A/gi, ":");
      const openInSidebar = (sessionId, file) => {
        if (typeof sessionId !== "string" || sessionId === "" || typeof file !== "string" || file === "") return false;
        const sidebar = ctx.get("sidebarRight");
        if (sidebar === void 0 || typeof sidebar.openResource !== "function") return false;
        const path = file.replace(/\\\\/g, "/").replace(/^(?:\\.\\/)+/, "");
        const address = "dsh-resource://file/session/" + encodeAddressSegment(sessionId)
          + "/" + path.split("/").map(encodeAddressSegment).join("/");
        try {
          sidebar.openResource(address, { kind: UNIVER_SIDEBAR_TAB_KIND });
          return true;
        } catch {
          return false;
        }
      };
      ctx.effect(
        () => ctx.slots.inject(
          "conversation.input.dock",
          () => ctx.slots.register(
            {
              name: "conversation.input.dock",
              id: "univer-dock",
              order: 400,
              locale: UNIVER_LOCALE_NAMESPACE,
              inject: () => ({ getViewerLocale, preferences, openInSidebar })
            },
            UniverDock
          )
        ),
        "univer: worktree dock"
      );`,
  ],
  // 2. The routing. Both hooks sit ahead of every early return, so the hook
  //    order is unchanged on all paths.
  [
    `      }, [turnFiles, livePreviewEnabled]);
      const files = Object.keys(open);`,
    `      }, [turnFiles, livePreviewEnabled]);
      ${MARK}
      const dockedFiles = React12.useRef(/* @__PURE__ */ new Set());
      React12.useEffect(() => {
        if (props.running !== true || !livePreviewEnabled || typeof props.openInSidebar !== "function") return;
        for (const target of Object.values(open)) {
          if (dockedFiles.current.has(target.file)) continue;
          if (props.openInSidebar(props.sessionId, target.file) === true) dockedFiles.current.add(target.file);
        }
      }, [open, props.running, livePreviewEnabled]);
      const files = Object.keys(open);`,
  ],
  // 3. A file the sidebar took does not also get a floating window. One it
  //    refused still does, which is the fallback.
  [
    `      const windows = Object.values(open);
      if (windows.length === 0) return /* @__PURE__ */ (0, import_jsx_runtime9.jsx)(import_jsx_runtime9.Fragment, {});`,
    `      const windows = Object.values(open).filter((target) => !dockedFiles.current.has(target.file)); ${MARK}
      if (windows.length === 0) return /* @__PURE__ */ (0, import_jsx_runtime9.jsx)(import_jsx_runtime9.Fragment, {});`,
  ],
];

for (const [anchor, replacement] of EDITS) {
  const n = s.split(anchor).length - 1;
  if (n !== 1) {
    console.error(`${file}: MATCH COUNT ${n} for ${JSON.stringify(anchor.slice(0, 60))} - the plugin changed, re-check before patching`);
    process.exit(1);
  }
  s = s.replace(anchor, replacement);
}

// Plugin files are hardlinks into the pnpm store: writing in place would
// corrupt the store copy, so the file is unlinked first (new inode).
rmSync(file, { force: true });
writeFileSync(file, s);
console.log(`${file}: univer edits open in the host right sidebar, floating window kept as the fallback`);
