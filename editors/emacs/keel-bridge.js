#!/usr/bin/env node
// keel-bridge.js --- host bridge between Emacs and the keel-wasm kernel
//
// Emacs cannot execute WebAssembly, so this Node process owns the kernel and
// speaks newline-delimited JSON over stdin/stdout.  One request object per
// line in, one response object per line out, correlated by `id`.
//
//   -->  {"id":1,"op":"hello"}
//   <--  {"id":1,"ok":true,"value":{...}}
//   -->  {"id":2,"op":"eval","program":[{"kind":"push","v":2},
//                                       {"kind":"push","v":3},
//                                       {"kind":"thread","xts":[5]}]}
//   <--  {"id":2,"ok":true,"value":{"stack":[5],"depth":1,"output":"",...}}
//
// Failures never throw out of the loop: they come back as
// {"id":N,"ok":false,"error":"...","value":{...state after the failure...}}.
//
// Usage: node keel-bridge.js /path/to/keel-wasm/pkg/keel_wasm.js
//
// The kernel has exactly thirteen primitives and NO text interpreter, so this
// bridge cannot accept Forth source.  It accepts a pre-parsed program whose
// steps are "push an integer" and "compile-and-run this thread of execution
// tokens".  Parsing is the caller's job (see keel.el); when keel-wasm grows an
// `interpret` export, the `hello` response advertises it in `capabilities` and
// the `interpret` op below starts working with no change here.

"use strict";

const BRIDGE_VERSION = "0.1.0";

const modulePath = process.argv[2];
if (!modulePath) {
  process.stderr.write("keel-bridge: no keel-wasm module path given\n");
  process.exit(2);
}

let Keel;
try {
  // eslint-disable-next-line import/no-dynamic-require
  ({ Keel } = require(modulePath));
} catch (e) {
  process.stderr.write(
    "keel-bridge: cannot load " + modulePath + ": " + describe(e) + "\n"
  );
  process.exit(3);
}
if (typeof Keel !== "function") {
  process.stderr.write(
    "keel-bridge: " + modulePath + " exports no Keel class\n"
  );
  process.exit(3);
}

// ---------------------------------------------------------------------------
// Kernel state
// ---------------------------------------------------------------------------

let vm = new Keel();

// `Keel.output()` is cumulative for the life of the kernel, so remember how
// much of it the client has already been shown and report only the delta.
let consumedOutput = 0;

// Primitive name -> execution token.  Built once; the set is fixed at 13.
const primitives = {};
for (const name of Keel.primitiveNames()) {
  primitives[name] = Keel.primitive(name);
}
const EXIT_XT = Keel.primitive("exit");

/** A keel error crosses the wasm boundary as a bare string, not an Error. */
function describe(e) {
  if (e === null || e === undefined) return "unknown error";
  if (typeof e === "string") return e;
  if (typeof e.message === "string" && e.message) return e.message;
  return String(e);
}

function outputDelta() {
  const all = vm.output();
  const delta = all.slice(consumedOutput);
  consumedOutput = all.length;
  return delta;
}

function state() {
  return {
    stack: Array.from(vm.stack()),
    depth: vm.depth(),
    output: outputDelta(),
  };
}

/**
 * Compile a thread, terminating it with `exit`.  The kernel's `compile` stores
 * exactly the tokens it is given, and a thread that does not end in `exit`
 * runs off into whatever cells follow it in the dictionary, so appending it is
 * not a convenience but a correctness requirement.
 */
function compileThread(xts) {
  const tokens = Array.from(xts);
  if (tokens.length === 0 || tokens[tokens.length - 1] !== EXIT_XT) {
    tokens.push(EXIT_XT);
  }
  return vm.compile(tokens);
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

/**
 * Run a pre-parsed program.  Steps execute strictly in order so that stack
 * effects interleave correctly: `2 3 + 4 +` is push, push, run [+], push,
 * run [+], because the kernel has no literal primitive to compile a number
 * into a thread.
 */
function opEval(req) {
  const program = req.program || [];
  let steps = 0;
  let threads = 0;
  for (const step of program) {
    switch (step.kind) {
      case "push":
        vm.push(step.v | 0);
        break;
      case "input":
        vm.setInput(String(step.s));
        break;
      case "thread": {
        const body = compileThread(step.xts);
        steps += vm.run(body);
        threads += 1;
        break;
      }
      default:
        throw "unknown program step `" + String(step.kind) + "'";
    }
  }
  const s = state();
  s.steps = steps;
  s.threads = threads;
  return s;
}

const ops = {
  hello() {
    return {
      bridgeVersion: BRIDGE_VERSION,
      nodeVersion: process.version,
      module: modulePath,
      primitives: Keel.primitiveNames(),
      xts: primitives,
      capabilities: {
        // True only once keel-wasm exports a text interpreter (milestone M4).
        interpret: typeof vm.interpret === "function",
      },
    };
  },
  eval: opEval,
  interpret(req) {
    if (typeof vm.interpret !== "function") {
      throw "this keel-wasm build exports no `interpret': the outer interpreter is a frames word and arrives at M4";
    }
    vm.interpret(String(req.text));
    return state();
  },
  push(req) {
    vm.push(req.value | 0);
    return state();
  },
  pop() {
    const value = vm.pop();
    const s = state();
    s.value = value;
    return s;
  },
  stack() {
    return state();
  },
  depth() {
    return state();
  },
  compile(req) {
    const body = compileThread(req.xts);
    const s = state();
    s.body = body;
    return s;
  },
  run(req) {
    const steps = vm.run(req.body >>> 0);
    const s = state();
    s.steps = steps;
    return s;
  },
  setInput(req) {
    vm.setInput(String(req.text));
    return state();
  },
  output() {
    return state();
  },
  reset() {
    vm.reset();
    consumedOutput = 0;
    return state();
  },
  // A brand new kernel: `reset` keeps the dictionary cells written so far,
  // this throws them away along with everything else.
  fresh() {
    vm = new Keel();
    consumedOutput = 0;
    return state();
  },
};

// ---------------------------------------------------------------------------
// Newline-delimited JSON loop
// ---------------------------------------------------------------------------

function reply(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

function handle(line) {
  let req;
  try {
    req = JSON.parse(line);
  } catch (e) {
    reply({ id: null, ok: false, error: "malformed request: " + describe(e) });
    return;
  }
  const id = req.id === undefined ? null : req.id;
  const op = ops[req.op];
  if (!op) {
    reply({ id, ok: false, error: "unknown op `" + String(req.op) + "'" });
    return;
  }
  try {
    reply({ id, ok: true, value: op(req) });
  } catch (e) {
    // Report the kernel state the failure left behind, so the client can show
    // the stack as it actually stands.
    let after = null;
    try {
      after = state();
    } catch (ignored) {
      after = null;
    }
    reply({ id, ok: false, error: describe(e), value: after });
  }
}

let pending = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  pending += chunk;
  let nl;
  while ((nl = pending.indexOf("\n")) >= 0) {
    const line = pending.slice(0, nl);
    pending = pending.slice(nl + 1);
    if (line.trim() !== "") handle(line);
  }
});
process.stdin.on("end", () => process.exit(0));
