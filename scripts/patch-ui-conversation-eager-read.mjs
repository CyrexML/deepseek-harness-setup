// Картинка в композере читается заранее, а не при отправке.
//
// ui-conversation хранит вложенную картинку как ссылку на браузерный File
// (browserDraftAttachment, src/client/service.ts:73) и читает байты только
// при отправке (encodeImage → FileReader, service.ts:124/260). Chrome/Android
// может обесценить File между вставкой и отправкой (снимок из буфера обмена,
// файл из пикера после сворачивания PWA, изменённый файл) → при отправке
// «The requested file could not be read, typically due to permission problems
// that have occurred after a reference to a file was acquired» (NotReadableError,
// 2026-09-17, телефон). Патч сразу после вставки снимает байты в память и
// подменяет ссылку на in-memory File; если чтение не успело — отправка идёт
// по старой ссылке, как раньше.
//
// Файл — сборка харнеса (не pnpm-store), `pnpm build` её перезапишет →
// слой в scripts/ensure-patches.sh. Идемпотентен (маркер).
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
