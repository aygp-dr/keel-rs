import init, { Keel } from './pkg/keel_wasm.js';
import { generate, differential, determinism, shrink, layoutFrom, replayTo, SPEC_QUESTIONS } from './engine.mjs';

await init();
const layout = layoutFrom(new Keel().boundaries());
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]);

// Green is a clean exit only; the step limit is grey; each error kind gets its own hue.
const ERROR_COLORS = ['#64748b', '#0f766e', '#7c3aed', '#a16207', '#be185d', '#0369a1', '#9a3412', '#475569', '#6d28d9'];
const outcomeColor = (o, i) => (o === 'exit' ? 'var(--ok)' : o === 'step limit' ? 'var(--line)' : ERROR_COLORS[i % ERROR_COLORS.length]);
let results = [];
let selected = null;

function kindOf(d) {
  if (!d) return 'ok';
  return SPEC_QUESTIONS.has(d.class) ? 'q' : 'bug';
}

async function runAll() {
  const int = (id, dflt) => { const v = parseInt($(id).value, 10); return Number.isFinite(v) && v > 0 ? v : dflt; };
  const seed0 = Math.max(0, parseInt($('seed').value, 10) || 0), n = int('cases', 500), limit = int('limit', 2000);
  $('go').disabled = true;
  results = [];
  const t0 = performance.now();
  for (let s = seed0; s < seed0 + n; s++) {
    const c = generate(s, layout);
    const r = differential(Keel, layout, c, limit);
    const d = r.divergence ?? determinism(Keel, layout, c, limit);
    results.push({ c, r, d });
    if ((s - seed0) % 100 === 99) {
      $('progress').textContent = `${s - seed0 + 1} / ${n}`;
      await new Promise((ok) => setTimeout(ok));
    }
  }
  $('progress').textContent = `${n} cases in ${((performance.now() - t0) / 1000).toFixed(1)} s`;
  $('go').disabled = false;
  summarize();
  list();
  const first = results.find((x) => kindOf(x.d) === 'bug') ?? results.find((x) => x.d) ?? results[0];
  if (first) pick(first.c.seed);
  history.replaceState(null, '', `#seed=${seed0}&cases=${n}&limit=${limit}`);
}

function summarize() {
  const steps = results.reduce((a, x) => a + x.r.steps, 0);
  const byClass = {};
  for (const x of results) if (x.d) byClass[x.d.class] = (byClass[x.d.class] ?? 0) + 1;
  const bugs = Object.entries(byClass).filter(([k]) => !SPEC_QUESTIONS.has(k)).reduce((a, [, v]) => a + v, 0);
  const tiles = [
    ['cases', results.length, ''],
    ['steps', steps.toLocaleString(), ''],
    ['kernel bugs', bugs, bugs ? 'bug' : 'ok'],
    ...Object.entries(byClass).map(([k, v]) => [k, v, SPEC_QUESTIONS.has(k) ? 'q' : 'bug']),
  ];
  $('tiles').innerHTML = tiles.map(([k, v, cls]) => `<div class="tile ${cls}"><b>${esc(v)}</b><span>${esc(k)}${cls === 'q' ? ' · spec question' : ''}</span></div>`).join('');
  const outcomes = {};
  for (const x of results) { const o = x.r.outcome.replace(/ \d+/g, ' N'); outcomes[o] = (outcomes[o] ?? 0) + 1; }
  const entries = Object.entries(outcomes).sort((a, b) => b[1] - a[1]);
  $('bar').innerHTML = entries.map(([k, v], i) => `<i style="width:${(100 * v) / results.length}%;background:${outcomeColor(k, i)}"></i>`).join('');
  $('legend').innerHTML = entries.map(([k, v], i) => `<span><i style="background:${outcomeColor(k, i)}"></i>${esc(k)} ${v}</span>`).join('');
  $('summary').hidden = false;
  $('work').hidden = false;
}

function list() {
  const order = { bug: 0, q: 1, ok: 2 };
  const sorted = results.slice().sort((a, b) => order[kindOf(a.d)] - order[kindOf(b.d)] || a.c.seed - b.c.seed);
  const shown = sorted.slice(0, 400);
  $('filter').textContent = sorted.length > shown.length ? `(first ${shown.length} of ${sorted.length}, divergent first)` : '';
  $('list').innerHTML = shown.map((x) => {
    const k = kindOf(x.d);
    const label = x.d ? x.d.class : x.r.outcome.startsWith('error') ? 'error' : x.r.outcome;
    return `<div class="case${selected === x.c.seed ? ' sel' : ''}" data-seed="${x.c.seed}"><span>seed ${x.c.seed}</span><span class="chip ${k === 'ok' && label === 'error' ? 'err' : k}">${esc(label)}</span></div>`;
  }).join('');
}

$('list').addEventListener('click', (e) => {
  const row = e.target.closest('[data-seed]');
  if (row) pick(+row.dataset.seed);
});

function threadHtml(c, at, threadIx, ip) {
  return c.defs.map((d, i) => {
    const toks = d.map((t, j) => {
      const addr = at[i] + 4 * j;
      const label = 'p' in t ? t.p : 'call' in t ? `T${t.call}` : `xt:${t.xt}`;
      return `<span class="t${addr === ip ? ' cur' : ''}" title="@${addr}">${esc(label)}</span>`;
    }).join('');
    return `<div class="muted" style="font-size:12px">T${i} @${at[i]}${c.runs.includes(i) ? ' · runs' : ''}${i === threadIx ? ' · current' : ''}</div><div class="thread">${toks}</div>`;
  }).join('');
}

const fmt = (v) => (Array.isArray(v) ? (v.length ? v.join(' ') : '—') : String(v));

function sideBySide(rep) {
  const rows = [
    ['ip', rep.keel.ip, rep.model.ip], ['sp', rep.keel.sp, rep.model.sp], ['rp', rep.keel.rp, rep.model.rp],
    ['data stack', rep.keel.stack, rep.model.stack], ['return stack', rep.keel.rstack, rep.model.rstack],
    ['output', rep.keel.output, rep.model.output],
  ];
  return `<div class="side"><span></span><span class="h">keel (wasm)</span><span class="h">model (js)</span>` +
    rows.map(([k, a, b]) => {
      const diff = fmt(a) !== fmt(b);
      return `<span class="k">${k}</span><span class="v${diff ? ' diff' : ''}">${esc(fmt(a))}</span><span class="v${diff ? ' diff' : ''}">${esc(fmt(b))}</span>`;
    }).join('') + `</div>`;
}

function pick(seed) {
  selected = seed;
  const x = results.find((y) => y.c.seed === seed) ?? (() => {
    const c = generate(seed, layout);
    const limit = +$('limit').value;
    const r = differential(Keel, layout, c, limit);
    return { c, r, d: r.divergence ?? determinism(Keel, layout, c, limit) };
  })();
  list();
  render(x, x.c, x.r.steps);
}

function render(x, c, at) {
  const limit = +$('limit').value;
  const total = differential(Keel, layout, c, limit).steps;
  const k = kindOf(x.d);
  const verdict = x.d
    ? `${x.d.class}${k === 'q' ? ' (spec question)' : ''} at run ${x.d.run ?? 0}, step ${x.d.step}: ${x.d.field} — keel ${JSON.stringify(x.d.keel)}, model ${JSON.stringify(x.d.model)}`
    : `agree for all ${total} steps; replay and restore give the same fingerprint · ${x.r.outcome}`;
  const twice = [replayTo(Keel, layout, c, total, limit).keel.fp, replayTo(Keel, layout, c, total, limit).keel.fp];
  $('inspect').innerHTML = `
    <h2>seed ${c.seed}${c !== x.c ? ' · shrunk' : ''}</h2>
    <div class="verdict ${k}">${esc(verdict)}</div>
    <div class="row muted" style="font-size:12px">
      <span>stack in: <code>${esc(c.stack.join(' ') || '—')}</code></span>
      <span>input: <code>${esc(c.input.join(' ') || '—')}</code></span>
      <span>runs: <code>${c.runs.map((t) => 'T' + t).join(' → ')}</code></span>
      <span>replayed twice: <span class="chip ${twice[0] === twice[1] ? 'ok' : 'bug'}">${twice[0] === twice[1] ? 'same fingerprint' : 'DIFFERENT'}</span></span>
    </div>
    <div class="row" style="margin:8px 0">
      <label style="flex:1">step <input id="scrub" type="range" min="0" max="${total}" value="${Math.min(at, total)}"></label>
      <button id="prev">◀</button><button id="next">▶</button>
      ${x.d && c === x.c ? '<button id="shrink">Shrink</button>' : ''}
    </div>
    <div id="view"></div>`;
  const view = () => {
    const n = +$('scrub').value;
    const rep = replayTo(Keel, layout, c, n, limit);
    const last = rep.last && (rep.last.keel || rep.last.model) ? `<div class="verdict q" style="font-size:12px">step ${rep.step}: keel ${esc(rep.last.keel ?? 'ok')} · model ${esc(rep.last.model ?? 'ok')}</div>` : '';
    $('view').innerHTML = `<div class="muted" style="font-size:12px;margin-bottom:4px">step ${rep.step} of ${total} · run ${rep.run} · fingerprint <code>${rep.keel.fp}</code></div>${last}${threadHtml(c, rep.at, rep.thread, rep.keel.ip)}${sideBySide(rep)}`;
  };
  $('scrub').addEventListener('input', view);
  $('prev').onclick = () => { $('scrub').value = Math.max(0, +$('scrub').value - 1); view(); };
  $('next').onclick = () => { $('scrub').value = Math.min(total, +$('scrub').value + 1); view(); };
  if ($('shrink')) $('shrink').onclick = () => {
    const small = shrink(Keel, layout, x.c, x.d, limit);
    const d = differential(Keel, layout, small, limit).divergence;
    render({ ...x, d: d ?? x.d }, small, (d ?? x.d).step + 1);
  };
  view();
}

$('go').addEventListener('click', runAll);
const params = new URLSearchParams(location.hash.slice(1));
// Whole numbers only: a link copied with trailing punctuation ("cases=500.")
// would otherwise leave the box empty and run no cases at all.
for (const k of ['seed', 'cases', 'limit']) {
  const n = parseInt(params.get(k) ?? '', 10);
  if (Number.isFinite(n) && n >= (k === 'seed' ? 0 : 1)) $(k).value = n;
}
if (location.hash) runAll();
