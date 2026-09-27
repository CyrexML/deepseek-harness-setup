// Tolerant matching for the edit tool. Idempotent.
//   node patch-fs-edit-tolerant.mjs [dsh_root]
//
// Why. edit matches old_string literally (packages/fs/fs-local/src/fsio.ts:821):
// anything but a byte-for-byte hit is "old_string was not found", and the model
// then re-reads the file and retries - two or three extra steps per edit.
// Measured over the 96 sessions in ~/.dsh/sessions: 289 such errors, of which
// 170 could be replayed against the file view the model actually had. In
// 104 of those 170 the text WAS in the file and differed only in leading or
// trailing whitespace, in 3 more only in the width of the gaps. Not one relaxed
// match was ambiguous.
//
// The cause is visible in the read tool's output: line numbers are not padded
// (packages/fs/tool-fs/src/read-render.ts:163 renders number + ": "), so the
// content column shifts by one at every digit boundary - 9 to 10, 99 to 100.
// A block copied out of that view carries an indent that is off by one.
//
// What this changes. When the literal match fails, the same text is looked for
// LINE BY LINE under three progressively weaker keys: trailing whitespace
// ignored, then indentation too, then runs of spaces collapsed. The first key
// that hits wins, and it is accepted only when the hit is unique (several hits
// raise the usual FS_AMBIGUOUS_EDIT instead of silently taking one). new_string
// is re-indented by the difference between the indent the model sent and the
// indent the file has, so the result keeps the file's own layout.
// If nothing matches, the error now carries the nearest anchor: the file's own
// lines around the place the first line of old_string points at, quoted
// verbatim, so the retry can copy from the error itself. That covers another 28
// of the 63 remaining cases; the rest are text the model invented, where no
// matcher can help.
//
// Written through unlink: package files may be hardlinks into the pnpm store.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';

const unlinkWrite = (p, d) => { rmSync(p, { force: true }); writeFileSync(p, d); };

const root = process.argv[2] || `${process.env.HOME}/tools/deepseek-harness`;
const path = join(root, 'packages/fs/fs-local/lib/index.js');
const MARK = 'dsh-local: tolerant edit match';

let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) { console.log('fs-local/lib/index.js: tolerant edit match already present'); process.exit(0); }

const HELPERS = `/* ${MARK} */
function __dshEditIndentOf(line) {
	const m = /^[ \\t]*/.exec(line);
	return m ? m[0] : "";
}
/** Move a block from the indent the model sent to the indent the file has. */
function __dshEditReindent(lines, oldIndent, fileIndent) {
	if (oldIndent === fileIndent) return lines;
	return lines.map((line) => {
		if (line.trim() === "") return line;
		if (oldIndent === "") return fileIndent + line;
		return line.startsWith(oldIndent) ? fileIndent + line.slice(oldIndent.length) : line;
	});
}
/** Progressively weaker line keys: trailing space, then indent, then inner gaps. */
const __DSH_EDIT_KEYS = [
	(line) => line.replace(/[ \\t]+$/, ""),
	(line) => line.trim(),
	(line) => line.replace(/[ \\t]+/g, " ").trim()
];
/**
 * Whole-line search for old_string when the literal one failed.
 * @returns the edited content, or null when no key produced a hit.
 */
function __dshEditRelaxed(content, oldNorm, newNorm, replaceAll, displayPath) {
	const fileLines = content.split("\\n");
	const oldLines = oldNorm.split("\\n");
	for (const key of __DSH_EDIT_KEYS) {
		const fileKeys = fileLines.map(key);
		const oldKeys = oldLines.map(key);
		const hits = [];
		for (let i = 0; i + oldKeys.length <= fileKeys.length; i++) {
			let j = 0;
			while (j < oldKeys.length && fileKeys[i + j] === oldKeys[j]) j++;
			if (j === oldKeys.length) { hits.push(i); i += oldKeys.length - 1; }
		}
		if (hits.length === 0) continue;
		if (hits.length > 1 && !replaceAll) throw new FsError(\`old_string matched \${hits.length} times in "\${displayPath}" once whitespace is ignored; provide a more specific old_string or set replace_all to true\`, "FS_AMBIGUOUS_EDIT");
		const newLines = newNorm.split("\\n");
		const oldIndent = __dshEditIndentOf(oldLines[0]);
		const out = fileLines.slice();
		for (let k = hits.length - 1; k >= 0; k--) {
			const at = hits[k];
			const fileIndent = __dshEditIndentOf(out[at]);
			out.splice(at, oldLines.length, ...__dshEditReindent(newLines, oldIndent, fileIndent));
		}
		return { content: out.join("\\n"), replacements: hits.length };
	}
	return null;
}
/** The file's own text around where old_string points, quoted for the retry. */
function __dshEditHint(content, oldNorm) {
	const first = oldNorm.split("\\n").map((l) => l.trim()).filter(Boolean)[0];
	if (first === undefined) return "";
	const fileLines = content.split("\\n");
	let at = fileLines.findIndex((l) => l.trim() === first);
	if (at < 0 && first.length >= 12) {
		const head = first.slice(0, Math.min(40, first.length));
		at = fileLines.findIndex((l) => l.includes(head));
	}
	if (at < 0) {
		const words = first.split(/\\s+/).slice(0, 4).join(" ");
		if (words.length >= 8) at = fileLines.findIndex((l) => l.includes(words));
	}
	if (at < 0) return ". No line of the file resembles the first line of old_string - re-read the file before editing";
	const from = Math.max(0, at - 2);
	const to = Math.min(fileLines.length, at + Math.min(8, oldNorm.split("\\n").length) + 2);
	const quoted = fileLines.slice(from, to).map((l, i) => \`\${from + i + 1}| \${l}\`).join("\\n");
	return \`. The closest place is line \${at + 1}; the file reads there:\\n\${quoted}\\nCopy old_string from these lines verbatim (without the "N| " prefix)\`;
}
`;

const ANCHOR = 'function applyLiteralEdit(content, oldString, newString, replaceAll, displayPath) {';
const OLD = '\tif (replacements === 0) throw new FsError(`old_string was not found in "${displayPath}"`, "FS_EDIT_NOT_FOUND");';
const NEW = [
	'\tif (replacements === 0) {',
	'\t\t/* dsh-local: tolerant edit match - whitespace drift before a hard failure */',
	'\t\tconst relaxed = __dshEditRelaxed(content, oldNorm, newNorm, replaceAll, displayPath);',
	'\t\tif (relaxed !== null) return relaxed;',
	'\t\tthrow new FsError(`old_string was not found in "${displayPath}"` + __dshEditHint(content, oldNorm), "FS_EDIT_NOT_FOUND");',
	'\t}',
].join('\n');

for (const [what, needle] of [['anchor', ANCHOR], ['not-found throw', OLD]]) {
	const n = s.split(needle).length - 1;
	if (n !== 1) { console.error(`fs-local/lib/index.js: MATCH COUNT ${n} for ${what}`); process.exit(1); }
}

s = s.replace(OLD, NEW).replace(ANCHOR, HELPERS + ANCHOR);
unlinkWrite(path, s);
console.log('fs-local/lib/index.js: tolerant edit match applied');
