// pi-ai: never hand the model an output budget of one token. Idempotent.
//
//   node patch-pi-ai-budget-floor.mjs [path/to/pi-ai/dist/api/simple-options.js]
//
// WHY. pi-ai sizes the reply by
//     available = contextWindow - estimateContextTokens(context) - 4096
//     max_tokens = min(maxTokens, max(MIN_MAX_TOKENS, available))
// with MIN_MAX_TOKENS = 1. The estimate is anchored on the usage of the last
// replayed assistant (that anchor is what patch-llm-pi-ai-usage.mjs stores),
// and that number describes the prefix AS IT WAS when the response was made.
// graph-memory rewrites history between turns - it archives a finished turn's
// tool steps and replaces older spans with a marker - so the anchor can describe
// a prefix several times larger than the one actually being sent.
//
// Measured on this stand, one session, six turns, four of them ended on
// max-tokens:
//     turn 3: real prompt 10 207 tokens of 65 536 -> output 1 token
//     turn 6: real prompt 16 500 tokens of 65 536 -> output 1 token
// The turn dies with "Output token limit reached" having produced nothing.
//
// WHAT THIS DOES. Raises that floor so a stale estimate costs a SHORT answer
// instead of a dead turn. The floor never exceeds what the caller asked for, so
// nothing is granted that the model was not already allowed.
//
// THE COST, stated plainly: when the context genuinely IS nearly full (the same
// session had two such turns, prompts of 60 638 and 64 450), the request now
// asks for more room than remains. llama.cpp stops the slot at the context end
// and reports the same max-tokens stop reason, so the outcome there is what it
// already was. The failure this removes is the one that produced nothing at all.
import { readFileSync, writeFileSync, rmSync } from 'node:fs';

const path = process.argv[2];
if (!path) { console.error('usage: patch-pi-ai-budget-floor.mjs <simple-options.js>'); process.exit(2); }

const MARK = '/* dsh-local: output budget floor */';
// 8192 and not a smaller number: the agent preset runs a reasoning budget of
// 5000, and pi-ai shrinks the thinking budget whenever maxTokens falls to it
// (clampThinkingBudgetToAnswerRoom), which would trade a dead turn for an
// answer with no reasoning left in it.
const FLOOR = 8192;

const ANCHOR = '    return Math.min(maxTokens, Math.max(MIN_MAX_TOKENS, available));';
const REPLACEMENT = `    ${MARK}
    return Math.min(maxTokens, Math.max(Math.min(maxTokens, ${FLOOR}), available));`;

let s = readFileSync(path, 'utf8');
if (s.includes(MARK)) { console.log('pi-ai: output budget floor already present'); process.exit(0); }
const n = s.split(ANCHOR).length - 1;
if (n !== 1) {
  console.error(`${path}: MATCH COUNT ${n} for the clamp - pi-ai changed, re-check before patching`);
  process.exit(1);
}
// The file is a hardlink into the pnpm store: writing in place would corrupt the
// store copy, so unlink first (new inode) and then write.
rmSync(path, { force: true });
writeFileSync(path, s.replace(ANCHOR, REPLACEMENT));
console.log(`${path}: output budget floor ${FLOOR} applied`);
