// Anchor pi-ai's context estimate on server usage (2026-09-13). Idempotent.
// usage: node patch-llm-pi-ai-usage.mjs [path/to/packages/llm/llm-pi-ai/lib/index.js]
//
// Why: pi-ai clamps max_tokens = contextWindow - estimate - 4096 (dist/api/simple-options.js).
// The estimate is usage-anchored ONLY when the last replayed assistant carries usage
// (dist/utils/estimate.js getLastAssistantUsageInfo); DSH replays every assistant with
// emptyPiUsage(), so pi-ai falls back to chars/4 over the whole history INCLUDING thinking
// blocks, which the local chat template (qwen3.8-agent.jinja) never sends to the server.
// Cooking_APP e86c8a24 turn 6: real prompt 44 324, estimate 128 815 -> max_tokens ~0, turn
// closed by max-tokens after 374 output tokens. With the anchor the declared contextWindow can
// be the real 65536 again.
//
// Three edits to the compiled bundle (lib/ is gitignored build output; a rebuild drops them —
// rerun this script after `pnpm build`):
//  1. toPiReplayState: store the response usage (minus its own reasoning tokens: the next prefix
//     never contains them) in replayState.response.usage. readReplayState ignores unknown keys.
//  2. replayedAssistant: restore that usage (validated) instead of emptyPiUsage().
//  3. piContext: if a compaction summary (source plugin "compact") follows the last assistant,
//     every replayed usage describes a prefix that no longer exists -> zero them, pi-ai falls
//     back to chars/4 for that one step (small: retained tail + summary).
import { readFileSync, writeFileSync } from 'node:fs';
const path = process.argv[2] || `${process.env.DSH_ROOT ?? `${process.env.HOME}/tools/deepseek-harness`}/packages/llm/llm-pi-ai/lib/index.js`;
const MARK = '/* dsh-local: replay usage */';
let s = readFileSync(path, 'utf8');
let applied = 0, skipped = 0;
// The anchor is a list of variants: signatures move between harness versions
// (0.1.6-alpha.2 added requestedModel/systemPrompt/providerThinkingLevel). The
// first variant occurring exactly once is used, and `{ANCHOR}` in the replacement
// text is substituted with it.
function edit(anchors, bRaw) {
  const list = Array.isArray(anchors) ? anchors : [anchors];
  const a = list.find(x => s.split(x).length - 1 === 1);
  const b = a === undefined ? bRaw : bRaw.split('{ANCHOR}').join(a);
  if (s.includes(b)) { skipped++; return; }
  if (a === undefined) {
    console.error(`MATCH COUNT ${list.map(x => `${JSON.stringify(x.slice(0, 60))}=${s.split(x).length - 1}`).join(', ')}`);
    process.exit(1);
  }
  s = s.replace(a, b); applied++;
}

// 1. writer
edit(
["function toPiReplayState(message) {", "function toPiReplayState(message, requestedModel = message.model) {"],
`${MARK}
// Usage of this response as the next request's prefix: totalTokens minus this response's own
// reasoning (chars/3.5, the token-meter ratio), since the local template drops reasoning on replay.
function replayUsage(message) {
	const u = message.usage;
	if (typeof u !== "object" || u === null || !(u.totalTokens > 0)) return {};
	let reasoningChars = 0;
	for (const b of message.content) if (b.type === "thinking" && typeof b.thinking === "string") reasoningChars += b.thinking.length;
	const reasoning = Math.min(u.output ?? 0, Math.ceil(reasoningChars / 3.5));
	return { usage: {
		input: u.input ?? 0,
		output: Math.max(0, (u.output ?? 0) - reasoning),
		cacheRead: u.cacheRead ?? 0,
		cacheWrite: u.cacheWrite ?? 0,
		totalTokens: Math.max(0, u.totalTokens - reasoning)
	} };
}
// Validated durable usage -> pi-ai usage (zero cost); anything malformed -> empty.
function replayedUsage(raw) {
	if (typeof raw !== "object" || raw === null) return emptyPiUsage();
	const keys = ["input", "output", "cacheRead", "cacheWrite", "totalTokens"];
	for (const k of keys) if (typeof raw[k] !== "number" || !(raw[k] >= 0)) return emptyPiUsage();
	return { ...emptyPiUsage(), input: raw.input, output: raw.output, cacheRead: raw.cacheRead, cacheWrite: raw.cacheWrite, totalTokens: raw.totalTokens };
}
// A compaction summary after the last assistant means every stored usage describes a prefix
// that no longer exists: zero them so pi-ai estimates by characters for this one request.
function dropStaleUsage(source, messages) {
	let last = -1;
	for (let i = 0; i < source.length; i++) if (source[i].role === "assistant") last = i;
	let stale = last < 0;
	for (let i = last + 1; i < source.length && !stale; i++) {
		const src = source[i].source;
		if (src !== void 0 && src.kind === "plugin" && src.plugin === "compact") stale = true;
	}
	if (!stale) return;
	for (const m of messages) if (m.role === "assistant") m.usage = emptyPiUsage();
}
{ANCHOR}`);

// 1b. writer: put usage into the response (spread into the object toPiReplayState returns)
edit(
["\t\treturn {\n\t\t\tresponse: {\n\t\t\t\tkind: \"pi-ai\",", "\treturn {\n\t\tresponse: {\n\t\t\tkind: \"pi-ai\","],
`{ANCHOR}
			${MARK} ...replayUsage(message),`);

// 2. reader
edit(
"\t\tusage: emptyPiUsage(),\n\t\tstopReason: state.response.stopReason,",
`		usage: replayedUsage(state.response.usage), ${MARK}
		stopReason: state.response.stopReason,`);

// 3. context
edit(
"\tconst tools = toolsOf(options);\n\treturn {",
`	const tools = toolsOf(options);
	dropStaleUsage(options.messages, messages); ${MARK}
	return {`);

writeFileSync(path, s);
console.log(`${path}: applied ${applied}, already present ${skipped}`);
