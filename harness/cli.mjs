#!/usr/bin/env node
// Headless run of the harness: node harness/cli.mjs [--seed N] [--cases N] [--limit N] [--show N]
//
// Exits 1 if any case finds a kernel bug (a state, memory, error-vs-ok,
// replay or restore divergence). Classes that are open questions for the spec
// (after-error, error-kind) are counted and shown, not failed on.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { initSync, Keel } from './pkg/keel_wasm.js';
import { generate, differential, determinism, shrink, show, layoutFrom, SPEC_QUESTIONS } from './engine.mjs';

const here = dirname(fileURLToPath(import.meta.url));
initSync({ module: readFileSync(join(here, 'pkg/keel_wasm_bg.wasm')) });

const arg = (name, dflt) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? Number(process.argv[i + 1]) : dflt;
};
const seed0 = arg('seed', 1), cases = arg('cases', 1000), limit = arg('limit', 2000), showN = arg('show', 3);

const layout = layoutFrom(new Keel().boundaries());
const counts = {}, outcomes = {}, first = {};
let steps = 0;
for (let s = seed0; s < seed0 + cases; s++) {
  const c = generate(s, layout);
  const r = differential(Keel, layout, c, limit);
  steps += r.steps;
  const o = r.outcome.replace(/ \d+/g, ' N');
  outcomes[o] = (outcomes[o] ?? 0) + 1;
  const d = r.divergence ?? determinism(Keel, layout, c, limit);
  if (d) {
    counts[d.class] = (counts[d.class] ?? 0) + 1;
    (first[d.class] ??= []).length < showN && first[d.class].push({ c, d });
  }
}

console.log(`seeds ${seed0}..${seed0 + cases - 1}: ${cases} cases, ${steps} steps`);
console.log('outcomes:', Object.entries(outcomes).sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k} ${v}`).join(', '));
console.log('divergences:', Object.keys(counts).length ? Object.entries(counts).map(([k, v]) => `${k} ${v}${SPEC_QUESTIONS.has(k) ? ' (spec question)' : ''}`).join(', ') : 'none');
for (const [cls, list] of Object.entries(first)) {
  for (const { c, d } of list) {
    const small = shrink(Keel, layout, c, d, limit);
    const again = differential(Keel, layout, small, limit).divergence ?? d;
    console.log(`\n[${cls}] seed ${c.seed}, step ${again.step}, ${again.field}: keel ${JSON.stringify(again.keel)} / model ${JSON.stringify(again.model)}`);
    console.log(show(layout, small).replace(/^/gm, '  '));
  }
}
const bugs = Object.keys(counts).filter((k) => !SPEC_QUESTIONS.has(k));
process.exit(bugs.length ? 1 : 0);
