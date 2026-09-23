// Read a pasted image eagerly, not at send time.
//
// ui-conversation keeps an attached image as a reference to a browser File
// (browserDraftAttachment, src/client/service.ts:73) and only reads the bytes
// when sending (encodeImage -> FileReader, service.ts:124/260). Chrome on Android
// can invalidate that File between the paste and the send - a clipboard
// screenshot, a file picked before the PWA was backgrounded, a file that changed -
// and the send then fails. The patch takes the bytes into memory right after the
// paste and swaps the reference for an in-memory File; if the read has not
// finished, sending falls back to the old reference exactly as before.
//
// The file belongs to the harness build (not the pnpm store) and `pnpm build`
// overwrites it, hence the layer in scripts/ensure-patches.sh. Idempotent (marker).
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
const path = process.argv[2] || `${process.env.HOME}/tools/deepseek-harness/packages/client/ui-conversation/lib/client.js`;
const MARK = '/* dsh-local: eager image read */';
let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) { console.log(`${path}: already patched`); process.exit(0); }
const a = `		function browserDraftAttachment(file) {
			return {
				kind: "image",
				id: randomUUID(),
				previewUrl: URL.createObjectURL(file),
				file
			};
		}`;
const n = s.split(a).length - 1;
if (n !== 1) { console.error(`MATCH COUNT ${n} for browserDraftAttachment`); process.exit(1); }
s = s.replace(a, `		function browserDraftAttachment(file) {
			const attachment = {
				kind: "image",
				id: randomUUID(),
				previewUrl: URL.createObjectURL(file),
				file
			};
			${MARK} // snapshot bytes now: the browser File may become unreadable before send
			file.arrayBuffer().then((buf) => {
				attachment.file = new File([buf], file.name, { type: file.type, lastModified: file.lastModified });
			}, () => {});
			return attachment;
		}`);
rmSync(path, { force: true });
writeFileSync(path, s);
console.log(`${path}: eager image read applied`);
