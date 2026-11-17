// Deterministic simulation harness for the keel.
//
// A case is data: a seed, the cells on the data stack, the bytes `key` will
// read, a few threads of execution tokens, and the runs: which threads to run,
// one after another, on the same machine. A run that ends in an error leaves
// what it left (return frames included) for the next one, as a host's error
// recovery would see it. The same case always builds the same machine, so a
// seed is a complete bug report.
//
// Each case runs two ways, one step at a time:
//   - on the keel (keel-wasm, the Rust kernel compiled to WebAssembly);
//   - on `Model` below, the thirteen primitives written again in JavaScript
//     from the Forth-2012 definitions of the standard words (@ ! 0= + um*
//     um/mod execute key emit exit) and the keel contracts for the rest
//     (sp@ rp@ nand, key's -1 at end of input).
// After every step the two must agree on the error (if any), the registers,
// both stacks and the output; at the end, on all of memory. A disagreement is
// classified, shrunk to a smallest case, and reported with its seed.
//
// Determinism is checked on the keel alone: the same case run twice must end
// in the same fingerprint, and a run snapshotted at step k, run on, and
// restored must finish exactly as the uninterrupted run did.

export const PRIMS = ['@', '!', 'sp@', 'rp@', '0=', '+', 'nand', 'exit', 'key', 'emit', 'execute', 'um*', 'um/mod'];
const XT = Object.fromEntries(PRIMS.map((n, i) => [n, i]));
const CELL = 4;
const SYS = { here: 0, latest: 1, state: 2, base: 3, hp: 4 };

// ---------------------------------------------------------------- the PRNG --

/** mulberry32: small, fast, and the same on every JavaScript engine. */
export function rng(seed) {
  let a = seed >>> 0;
  const next = () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return (t ^ (t >>> 14)) >>> 0;
  };
  const below = (n) => next() % n;
  return { next, below, pick: (xs) => xs[below(xs.length)], chance: (p) => next() / 2 ** 32 < p };
}

// ------------------------------------------------------------ the layout --

/** The memory map, from the keel's own boundaries (R-K-04). */
export function layoutFrom(b) {
  const [sys, tib, dict, fromSpace, toSpace, dataStack, returnStack, end] = Array.from(b);
  return { sys, tib, dict, fromSpace, toSpace, dataStack, returnStack, end, dataTop: returnStack, returnTop: end };
}

/** Body address of each thread: they are compiled one after another from the start of the dictionary. */
export function bodies(layout, defs) {
  const out = [];
  let at = layout.dict;
  for (const d of defs) {
    out.push(at);
    at += d.length * CELL;
  }
  return out;
}

/** A thread's tokens as numbers: {p:'+'} is a primitive, {call:k} the body of thread k, {xt:n} a raw token. */
export function resolve(layout, defs) {
  const at = bodies(layout, defs);
  return defs.map((d) => d.map((t) => ('p' in t ? XT[t.p] : 'call' in t ? at[t.call] : t.xt | 0)));
}

// --------------------------------------------------------- the generator --

/** Values that sit on the edges where kernels go wrong. */
function edgeValues(layout, at) {
  const L = layout;
  return [
    0, 1, -1, 2, 3, 4, 7, 12, 13, 255, 256, 0x7fffffff, -0x80000000, 0xffff, 0x10000,
    L.sys, L.sys + 1, L.tib, L.dict, L.dict - 4, L.fromSpace, L.toSpace,
    L.dataStack, L.dataTop - 4, L.dataTop, L.returnStack, L.returnTop - 4, L.returnTop,
    L.end - 4, L.end, L.end + 4, -4, ...at,
  ].map((v) => v | 0);
}

/** Primitive weights: the stack-shufflers and arithmetic come up often, exit less (it ends threads). */
const WEIGHTED = [
  '+', '+', 'nand', 'nand', '0=', '0=', '@', '@', '!', '!', 'sp@', 'sp@', 'rp@',
  'um*', 'um*', 'um/mod', 'um/mod', 'key', 'emit', 'execute', 'execute', 'exit',
];

export function generate(seed, layout) {
  const r = rng(seed);
  const nDefs = 1 + r.below(3);
  const defs = [];
  for (let k = 0; k < nDefs; k++) {
    const len = r.below(12);
    const d = [];
    for (let i = 0; i < len; i++) {
      if (k > 0 && r.chance(0.12)) d.push({ call: r.below(k + 1) }); // earlier threads, or itself
      else if (r.chance(0.03)) d.push({ xt: r.pick([13, -1, 2 ** 31 - 1, layout.dict + 2]) });
      else d.push({ p: r.pick(WEIGHTED) });
    }
    d.push({ p: 'exit' });
    defs.push(d);
  }
  const values = edgeValues(layout, bodies(layout, defs));
  const stack = Array.from({ length: r.below(7) }, () => (r.chance(0.7) ? r.pick(values) : r.next() | 0));
  const input = Array.from({ length: r.below(4) }, () => r.pick([0, 10, 65, 107, 127, 128, 255, r.below(256)]));
  const runs = [nDefs - 1];
  while (runs.length < 3 && r.chance(0.3)) runs.push(r.below(nDefs));
  return { seed, stack, input, defs, runs };
}

// ------------------------------------------------------------- the model --

class Fault extends Error {}

const MESSAGES = {
  dsu: () => 'data stack underflow',
  dso: () => 'data stack overflow',
  rsu: () => 'return stack underflow',
  rso: () => 'return stack overflow',
  unaligned: (a) => `unaligned address ${a}`,
  range: (a) => `address ${a} outside memory`,
  div0: () => 'divide by zero',
  quot: () => 'quotient does not fit in a cell',
};
const fault = (k, a) => new Fault(MESSAGES[k](a));

/**
 * The thirteen primitives again, written from the standard and the keel
 * contracts rather than from the Rust. One deliberate difference in kind:
 * a primitive here checks everything it needs before it changes anything,
 * so an error leaves the machine as it was. Where the two disagree only after
 * an error, the harness says so under its own class.
 */
export class Model {
  constructor(layout) {
    this.L = layout;
    this.mem = new Uint8Array(layout.end);
    this.dv = new DataView(this.mem.buffer);
    this.sp = layout.dataTop;
    this.rp = layout.returnTop;
    this.ip = 0;
    this.rpFloor = this.rp;
    this.running = false;
    this.input = [];
    this.inPos = 0;
    this.output = [];
    this.poke(layout.sys + SYS.here * CELL, layout.dict);
    this.poke(layout.sys + SYS.base * CELL, 10);
    this.poke(layout.sys + SYS.hp * CELL, layout.fromSpace);
  }

  check(a) {
    a >>>= 0;
    if (a % CELL) throw fault('unaligned', a);
    if (a + CELL > this.L.end) throw fault('range', a);
    return a;
  }
  peek(a) { return this.dv.getInt32(this.check(a), true); }
  poke(a, v) { this.dv.setInt32(this.check(a), v | 0, true); }

  depth() { return (this.L.dataTop - this.sp) / CELL; }
  rdepth() { return (this.L.returnTop - this.rp) / CELL; }
  need(n) { if (this.depth() < n) throw fault('dsu'); }
  room(n) { if (this.sp - n * CELL < this.L.dataStack) throw fault('dso'); }
  push(v) { this.room(1); this.sp -= CELL; this.poke(this.sp, v); }
  pop() { this.need(1); const v = this.peek(this.sp); this.sp += CELL; return v; }
  rpush(v) { if (this.rp - CELL < this.L.returnStack) throw fault('rso'); this.rp -= CELL; this.poke(this.rp, v); }
  rpop() { if (this.rdepth() < 1) throw fault('rsu'); const v = this.peek(this.rp); this.rp += CELL; return v; }
  nth(i) { return this.peek(this.sp + i * CELL); } // 0 is the top

  stack() { const out = []; for (let a = this.L.dataTop - CELL; a >= this.sp; a -= CELL) out.push(this.peek(a)); return out; }
  rstack() { const out = []; for (let a = this.L.returnTop - CELL; a >= this.rp; a -= CELL) out.push(this.peek(a)); return out; }

  /** Take the keel's whole state, so later runs compare from common ground. */
  load(snap) {
    const dv = new DataView(snap.buffer, snap.byteOffset, snap.byteLength);
    let at = 13;
    this.mem.set(snap.subarray(at, at + this.L.end)); at += this.L.end;
    const u32 = () => { const v = dv.getUint32(at, true); at += 4; return v; };
    this.sp = u32(); this.rp = u32(); this.ip = u32(); this.rpFloor = u32();
    this.running = snap[at++] !== 0;
    this.inPos = u32();
    let n = u32(); this.input = Array.from(snap.subarray(at, at + n)); at += n;
    n = u32(); this.output = Array.from(snap.subarray(at, at + n));
  }

  compile(threads) {
    let here = this.L.dict;
    for (const t of threads) for (const x of t) { this.poke(here, x); here += CELL; }
    this.poke(this.L.sys + SYS.here * CELL, here);
  }

  begin(body) { this.ip = body >>> 0; this.rpFloor = this.rp; this.running = true; }

  step() {
    const xt = this.peek(this.ip);
    this.ip = (this.ip + CELL) >>> 0;
    this.exec(xt);
    return this.running;
  }

  exec(xt) {
    if (xt >= 0 && xt < PRIMS.length) return this.prim(PRIMS[xt]);
    this.rpush(this.ip);
    this.ip = xt >>> 0;
  }

  prim(name) {
    switch (name) {
      case '@': { this.need(1); const v = this.peek(this.nth(0)); this.sp += CELL; return this.push(v); }
      case '!': { this.need(2); this.check(this.nth(0)); const a = this.pop(), x = this.pop(); return this.poke(a, x); }
      case 'sp@': { this.room(1); return this.push(this.sp); }
      case 'rp@': { this.room(1); return this.push(this.rp); }
      case '0=': { this.need(1); return this.push(this.pop() === 0 ? -1 : 0); }
      case '+': { this.need(2); const b = this.pop(), a = this.pop(); return this.push((a + b) | 0); }
      case 'nand': { this.need(2); const b = this.pop(), a = this.pop(); return this.push(~(a & b)); }
      case 'exit':
        if (this.rp >= this.rpFloor) { this.running = false; return; }
        this.ip = this.rpop() >>> 0; return;
      case 'key': { this.room(1); const c = this.inPos < this.input.length ? this.input[this.inPos] : -1; this.push(c); if (c !== -1) this.inPos++; return; }
      case 'emit': { this.output.push(this.pop() & 0xff); return; }
      case 'execute': { this.need(1); const xt = this.nth(0); this.sp += CELL; return this.exec(xt); }
      case 'um*': {
        this.need(2);
        const p = BigInt(this.nth(1) >>> 0) * BigInt(this.nth(0) >>> 0);
        this.sp += 2 * CELL;
        this.push(Number(p & 0xffffffffn) | 0);
        return this.push(Number(p >> 32n) | 0);
      }
      case 'um/mod': {
        this.need(3);
        const u = BigInt(this.nth(0) >>> 0);
        if (u === 0n) throw fault('div0');
        const d = (BigInt(this.nth(1) >>> 0) << 32n) | BigInt(this.nth(2) >>> 0);
        const q = d / u;
        if (q > 0xffffffffn) throw fault('quot');
        this.sp += 3 * CELL;
        this.push(Number(d % u) | 0);
        return this.push(Number(q) | 0);
      }
    }
  }
}

// ------------------------------------------------------------- running --

function keelFor(Keel, layout, c) {
  const k = new Keel();
  const threads = resolve(layout, c.defs);
  const want = bodies(layout, c.defs);
  threads.forEach((t, i) => {
    const body = k.compile(Int32Array.from(t));
    if (body !== want[i]) throw new Error(`harness: thread ${i} compiled at ${body}, expected ${want[i]}`);
  });
  for (const v of c.stack) k.push(v);
  k.setInputBytes(Uint8Array.from(c.input));
  return k;
}

function modelFor(layout, c) {
  const m = new Model(layout);
  m.compile(resolve(layout, c.defs));
  for (const v of c.stack) m.push(v);
  m.input = c.input.slice();
  return m;
}

const tryStep = (f) => { try { return { ok: true, running: f() }; } catch (e) { return { ok: false, err: String(e.message ?? e) }; } };
const same = (a, b) => a.length === b.length && a.every((v, i) => v === b[i]);

/** What the keel and the model look like at one moment. */
function views(k, m) {
  return [
    ['ip', k.ip(), m.ip >>> 0],
    ['sp', k.sp(), m.sp >>> 0],
    ['rp', k.rp(), m.rp >>> 0],
    ['data stack', Array.from(k.stack()), m.stack()],
    ['return stack', Array.from(k.rstack()), m.rstack()],
    ['output', Array.from(k.outputBytes()), m.output],
  ];
}

/**
 * Run one case on both, step by step, run after run. Returns
 * {steps, outcome, divergence?}: outcome is how the last run ended ('exit',
 * 'error: …', 'step limit'); divergence is {class, run, step, field, keel,
 * model}. A kernel-bug class returns at once. A spec-question class (the two
 * agree there was an error but not on what it left, or on which error) is
 * remembered, the model takes the keel's state, and the case goes on, so a
 * later run can still find a bug.
 */
export function differential(Keel, layout, c, limit = 2000) {
  const k = keelFor(Keel, layout, c);
  const m = modelFor(layout, c);
  const at = bodies(layout, c.defs);
  let steps = 0, outcome = 'exit', question = null;
  const bug = (d) => ({ steps, outcome: 'diverged', divergence: d });
  for (let run = 0; run < c.runs.length; run++) {
    k.begin(at[c.runs[run]]);
    m.begin(at[c.runs[run]]);
    outcome = 'step limit';
    for (let step = 0; steps < limit; step++, steps++) {
      const a = tryStep(() => k.step());
      const b = tryStep(() => m.step());
      const where = { run, step };
      if (a.ok !== b.ok) return bug({ class: 'error-vs-ok', ...where, field: 'error', keel: a.err ?? 'ok', model: b.err ?? 'ok' });
      if (!a.ok) {
        steps++;
        outcome = `error: ${a.err}`;
        let d = a.err !== b.err ? { class: 'error-kind', ...where, field: 'error', keel: a.err, model: b.err } : null;
        for (const [field, x, y] of views(k, m)) {
          if (!d && (Array.isArray(x) ? !same(x, y) : x !== y)) d = { class: 'after-error', ...where, field, keel: x, model: y };
        }
        if (d) { question ??= d; m.load(k.snapshot()); }
        break;
      }
      for (const [field, x, y] of views(k, m)) {
        if (Array.isArray(x) ? !same(x, y) : x !== y) return bug({ class: 'state', ...where, field, keel: x, model: y });
      }
      if (a.running !== b.running) return bug({ class: 'state', ...where, field: 'running', keel: a.running, model: b.running });
      if (!a.running) { steps++; outcome = 'exit'; break; }
    }
    if (outcome === 'step limit') break;
  }
  const mem = k.snapshot().subarray(13, 13 + layout.end);
  for (let i = 0; i < layout.end; i++) {
    if (mem[i] !== m.mem[i]) return bug({ class: 'memory', run: c.runs.length - 1, step: steps, field: `byte ${i}`, keel: mem[i], model: m.mem[i] });
  }
  return question ? { steps, outcome, divergence: question } : { steps, outcome };
}

/**
 * Step a keel through the case's runs, starting inside run `run0` (already
 * begun, or restored mid-way), until every run has ended or `limit` total
 * steps; returns the fingerprint. `n` is how many steps were taken before.
 */
function drive(k, layout, c, limit, run0 = 0, n = 0) {
  const at = bodies(layout, c.defs);
  for (let i = run0; i < c.runs.length; i++) {
    if (i > run0) k.begin(at[c.runs[i]]);
    while (n < limit && k.running()) { n++; if (!tryStep(() => k.step()).ok) break; }
  }
  return k.fingerprint();
}

/** Same case, same end; and a snapshot taken a few steps in restores to the same end, in the same kernel or a fresh one. */
export function determinism(Keel, layout, c, limit = 2000) {
  const at = bodies(layout, c.defs);
  const start = () => { const k = keelFor(Keel, layout, c); k.begin(at[c.runs[0]]); return k; };
  const a = drive(start(), layout, c, limit);
  const b = drive(start(), layout, c, limit);
  if (a !== b) return { class: 'replay', run: 0, step: 0, field: 'fingerprint', keel: a, model: b };
  // Cut only after steps that succeeded. An error leaves the keel's run flag
  // set (the run stopped, it did not finish), so a snapshot taken after one
  // would look like a live run and restoring it would step on past the error.
  const k = start();
  let cut = 0, snap = k.snapshot();
  while (cut < c.seed % 8 && k.running()) {
    if (!tryStep(() => k.step()).ok) break;
    cut++;
    snap = k.snapshot();
  }
  k.restore(snap);
  const fresh = new Keel();
  fresh.restore(snap);
  drive(k, layout, c, limit, 0, cut);
  k.restore(snap);
  const again = drive(k, layout, c, limit, 0, cut);
  if (again !== a) return { class: 'restore', run: 0, step: cut, field: 'fingerprint', keel: again, model: a };
  const other = drive(fresh, layout, c, limit, 0, cut);
  if (other !== a) return { class: 'restore', run: 0, step: cut, field: 'fingerprint (fresh kernel)', keel: other, model: a };
  return null;
}

// ------------------------------------------------------------ shrinking --

/** Smaller variants of a case, most aggressive first. */
function* smaller(c) {
  for (let i = 0; c.runs.length > 1 && i < c.runs.length; i++) yield { ...c, runs: c.runs.filter((_, j) => j !== i) };
  const main = c.defs.length;
  for (let k = 0; k < main; k++) {
    // drop a whole helper thread, renumbering calls past it; calls to it become exits
    const defs = c.defs.filter((_, i) => i !== k).map((d) => d.map((t) => ('call' in t ? (t.call === k ? { p: 'exit' } : { call: t.call > k ? t.call - 1 : t.call }) : t)));
    const runs = c.runs.filter((t) => t !== k).map((t) => (t > k ? t - 1 : t));
    if (runs.length) yield { ...c, defs, runs };
  }
  for (let k = 0; k < main; k++) {
    for (let i = c.defs[k].length - 2; i >= 0; i--) {
      const defs = c.defs.slice(); defs[k] = defs[k].filter((_, j) => j !== i); yield { ...c, defs };
    }
  }
  for (let i = 0; i < c.stack.length; i++) yield { ...c, stack: c.stack.filter((_, j) => j !== i) };
  for (let i = 0; i < c.input.length; i++) yield { ...c, input: c.input.filter((_, j) => j !== i) };
  for (let i = 0; i < c.stack.length; i++) {
    for (const v of [0, 1, -1]) if (c.stack[i] !== v) { const stack = c.stack.slice(); stack[i] = v; yield { ...c, stack }; }
  }
}

/** Greedy shrink: keep any smaller case that still diverges the same way. */
export function shrink(Keel, layout, c, divergence, limit = 2000, budget = 400) {
  let best = c, tries = 0;
  const keep = (d) => d && d.class === divergence.class && d.field === divergence.field;
  for (let improved = true; improved && tries < budget; ) {
    improved = false;
    for (const s of smaller(best)) {
      if (++tries > budget) break;
      const d = differential(Keel, layout, s, limit).divergence;
      if (keep(d)) { best = s; improved = true; break; }
    }
  }
  return best;
}

// ------------------------------------------------------------- printing --

export function show(layout, c) {
  const at = bodies(layout, c.defs);
  const tok = (t) => ('p' in t ? t.p : 'call' in t ? `T${t.call}` : `xt:${t.xt}`);
  return [
    `stack: ${c.stack.join(' ') || '(empty)'}`,
    `input: ${c.input.length ? c.input.join(' ') : '(none)'}`,
    ...c.defs.map((d, i) => `T${i} @${at[i]}: ${d.map(tok).join(' ')}`),
    `runs: ${c.runs.map((t) => `T${t}`).join(', then ')}`,
  ].join('\n');
}

/** Classes that are questions for the spec rather than bugs in the kernel. */
export const SPEC_QUESTIONS = new Set(['after-error', 'error-kind']);

// --------------------------------------------------------------- replay --

/**
 * Replay a case on both to global step `target` (or its end) and return what
 * each looks like there. Deterministic, so the UI scrubs by replaying from the
 * seed instead of storing a snapshot per step.
 */
export function replayTo(Keel, layout, c, target, limit = 2000) {
  const k = keelFor(Keel, layout, c);
  const m = modelFor(layout, c);
  const at = bodies(layout, c.defs);
  let n = 0, run = 0, last = null, ended = false, resync = false;
  outer: for (; run < c.runs.length; run++) {
    // After both errored, the model takes the keel's state only when the next
    // run starts, so a view of the error step itself still shows them differ.
    if (resync) { m.load(k.snapshot()); resync = false; }
    k.begin(at[c.runs[run]]);
    m.begin(at[c.runs[run]]);
    while (n < limit) {
      if (n >= target) break outer;
      const a = tryStep(() => k.step());
      const b = tryStep(() => m.step());
      n++;
      last = { keel: a.ok ? null : a.err, model: b.ok ? null : b.err };
      if (!a.ok || !b.ok) {
        if (!a.ok && !b.ok) resync = true;
        if (a.ok !== b.ok) break outer;
        break;
      }
      if (!a.running) break;
    }
    if (n >= limit) break;
  }
  if (run >= c.runs.length) { run = c.runs.length - 1; ended = true; }
  const state = (x, isKeel) => isKeel
    ? { ip: x.ip(), sp: x.sp(), rp: x.rp(), stack: Array.from(x.stack()), rstack: Array.from(x.rstack()), output: Array.from(x.outputBytes()), fp: x.fingerprint() }
    : { ip: x.ip >>> 0, sp: x.sp >>> 0, rp: x.rp >>> 0, stack: x.stack(), rstack: x.rstack(), output: x.output.slice() };
  return { step: n, run, ended, last, keel: state(k, true), model: state(m, false), thread: c.runs[run], at };
}
