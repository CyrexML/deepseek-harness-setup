// token-meter: stop pricing reasoning the local template never sends. Idempotent.
//
//   node patch-token-meter-reasoning.mjs [path/to/token-meter/lib/index.js]
//
// WHY. The meter decides when compaction runs. It prices content with a fixed
// heuristic (`estimateContent`, src/estimate.ts:47) in which `case "text"` and
// `case "reasoning"` share one arm - a reasoning block costs chars/4 exactly
// like visible text. It then prefers the provider's real usage ONLY when that
// usage is at least as large as its own estimate (src/index.ts:168), so a
// heuristic that runs high is never corrected: the estimate always wins.
//
// This stand's chat template replays no reasoning at all. templates/
// chat-agent.jinja:127 emits the `<think>` block only under `preserve_thinking`
// or, for the newest assistant message, `keep_last_thinking`; neither is set,
// so every past step's reasoning is dropped before the prompt is built. The
// meter is therefore charging for text that is never sent.
//
// MEASURED, one 64-turn working session, 93 compactions with a usable
// pair of numbers. For each one, the span the compactor shadowed, priced two
// ways - by the meter, and by llama-server tokenizing the very same content as
// the summarizer's prompt:
//
//     shadowed span, chars                     124 446   (46% of it reasoning)
//     meter's price                              30 317 tokens
//     server's count of the same content         22 515 tokens
//     => the meter runs 35% high
//
// Implied density confirms which number is real: 2.96 chars/token over the span
// WITHOUT reasoning - ordinary for this Cyrillic-heavy text - against 5.53 with
// it, which no tokenizer produces. The reasoning is phantom.
//
// The cost of that: a threshold of 45 056 estimated tokens is reached at about
// 33 000 real ones, so roughly a third of a 65 536 window is never used, and
// compaction ran 130 times across the two sessions - one per 27 steps - for
// 3.1M tokens of summarizer work and 1.6 h of wall clock.
//
// WHAT THIS CHANGES. A reasoning block is priced at zero, framing included: a
// block that is not sent has no framing either. Nothing else moves - the
// threshold, the ratios and the engine's decision logic are untouched. This is
// deliberately a change to the MEASUREMENT and not to the decision: an earlier
// attempt to veto compaction from a usage anchor (compaction-notools.mjs,
// `compactIfNeeded`, removed 2026-10-02) misjudged whenever graph-memory wrote
// a prune and suppressed compaction entirely.
//
// THE ONE PLACE IT ERRS, stated plainly. `_estimateProviderAssistant`
// (lib/index.js:789) prices the anchor's OWN freshly streamed reply, and there
// reasoning is real: the server counted it in `usage.outputTokens`. Zeroing it
// makes the estimate smaller, so `usage >= estimate` now holds and the meter
// switches to the server's own number as its baseline - which is the better
// input. The baseline then carries one step's reasoning that will not be
// resent: a bounded overhead of one reasoning budget (~5 000 tokens here),
// erring toward compacting slightly early rather than late.
//
// Not a change to make upstream: wherever the provider replays reasoning, the
// stock pricing is correct. This is a property of this stand's template, so it
// is a local layer.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';

const path = process.argv[2]
  || `${process.env.DSH_ROOT ?? `${process.env.HOME}/tools/deepseek-harness`}/packages/llm/token-meter/lib/index.js`;

const MARK = '/* dsh-local: reasoning is not replayed, so it is not priced */';

const ANCHOR = '\t\tcase "text":\n'
  + '\t\tcase "reasoning":\n'
  + '\t\t\ttokens += Math.ceil(block.text.length / CHARS_PER_TOKEN) + BLOCK_OVERHEAD;\n'
  + '\t\t\tbreak;';

const REPLACEMENT = '\t\tcase "reasoning":\n'
  + `\t\t\t${MARK}\n`
  + '\t\t\tbreak;\n'
  + '\t\tcase "text":\n'
  + '\t\t\ttokens += Math.ceil(block.text.length / CHARS_PER_TOKEN) + BLOCK_OVERHEAD;\n'
  + '\t\t\tbreak;';

let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) { console.log('token-meter: reasoning already unpriced'); process.exit(0); }

const n = s.split(ANCHOR).length - 1;
if (n !== 1) {
  console.error(`${path}: MATCH COUNT ${n} for the text/reasoning arm - the meter changed, re-check before patching`);
  process.exit(1);
}

// Built output of the harness itself, not a pnpm hardlink; a plain write is
// right here, but unlinking first costs nothing and is what every sibling does.
rmSync(path, { force: true });
writeFileSync(path, s.replace(ANCHOR, REPLACEMENT));
console.log(`${path}: reasoning blocks priced at zero`);
