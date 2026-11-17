# keel-rs

[![ci](https://github.com/aygp-dr/keel-rs/actions/workflows/ci.yml/badge.svg)](https://github.com/aygp-dr/keel-rs/actions/workflows/ci.yml)
[![milestone M2](https://img.shields.io/badge/milestone-M2%20native-blue)](https://github.com/aygp-dr/forth-keel)
[![primitives 13](https://img.shields.io/badge/primitives-13-informational)](#the-thirteen-primitives)
[![cell 32-bit](https://img.shields.io/badge/cell-32--bit-informational)](#cells)
[![rust 1.74+](https://img.shields.io/badge/rust-1.74%2B-orange)](#building)

The Rust **keel** for [forth-keel](https://github.com/aygp-dr/forth-keel): the
bottom layer of a Forth system built in three layers, each written on top of
the one below. The keel is the only part written in a host language. Everything
above it — `frames` (stack words, arithmetic, control flow, compiler, outer
interpreter) and `planking` (tagged cells, pairs, symbols, closures, promises,
Cheney GC, reader) — is written in Forth on top of these thirteen primitives.

The governing specification lives in
[forth-keel/spec.org](https://github.com/aygp-dr/forth-keel/blob/main/spec.org).
Requirement IDs quoted below (`R-K-01`, …) are defined there, and the tests in
this repository are named after them.

| Crate | What it is | Gate |
|-------|------------|------|
| [`keel/`](keel/) | The kernel: memory, two stacks, 13 primitives, NEXT inner interpreter | `cargo test` (M2) |
| [`keel-wasm/`](keel-wasm/) | wasm-bindgen shim for JavaScript hosts | `cargo build --target wasm32-unknown-unknown` (M4) |

## The thirteen primitives

R-K-01 fixes the set exactly. Nothing may be added to it; every other Forth word
is derived from these, in Forth:

```
@  !  sp@  rp@  0=  +  nand  exit  key  emit  execute  um*  um/mod
```

`nand` is the only logical primitive — `invert`, `and`, `or` and `negate` are
all derived from it. `sp@` yields the address holding the former top of stack,
which is what makes `dup` definable as `sp@ @`.

## Cells

R-K-03: cells are at least 32 bits, and the oracle corpus assumes no more than
32. So a cell here is exactly `i32` on every host, which keeps results identical
between this kernel and a 32-bit wasm host.

## Memory

R-K-04: one linear, byte-addressed region, in the order the spec's memory map
gives, every boundary cell-aligned:

```
system variables | TIB | dictionary -> | from-space | to-space | <- data stack | <- return stack
```

Both stacks grow down. The two semispaces are equal in size, for the copying
collector that `planking` will add at M8.

## Building

```sh
cargo test --all                                      # native, M2
cargo build -p keel-wasm --target wasm32-unknown-unknown   # wasm32, M4
cargo fmt --all --check && cargo clippy --all-targets -- -D warnings
```

Requires Rust 1.74+. For the wasm target: `rustup target add
wasm32-unknown-unknown` (the FreeBSD `rust` package already bundles it, so
`rustup` is not needed there). CI runs all of the above on every push.

`keel/tests/properties.rs` holds property tests with
[Hegel](https://antithesis.com/blog/2026/hegel/) (`hegeltest`, a dev-dependency
only; the kernel stays dependency-free): each arithmetic primitive against exact
integer arithmetic, and a state machine that keeps the data stack equal to a
`Vec` model after every step, errors included. The pattern, and the rule that
state-machine invariants are `always_run`, come from oxidecomputer/iddqd.
Running them needs Rust 1.86+ (hegeltest's floor).

Two of those need a newer toolchain than the build does. The clippy gate
fails on clippy 1.89 with `unknown lint: clippy::manual_is_multiple_of` (the
`#[allow]` in `keel/src/lib.rs` names a lint 1.89 does not have, and `-D
warnings` makes that an error), and installing `wasm-pack` needs rustc 1.91
or newer. Both pass on 1.100.

On macOS (verified 2026-11-15, macOS 15.1 arm64, Rust 1.100): `cargo fmt`,
`cargo clippy`, `cargo test --all` (26 tests) and the wasm32 release build
all pass. For the Node build that `editors/emacs` and forth-keel's
experiments 008-010 load:

```sh
rustup update stable
rustup target add wasm32-unknown-unknown
cargo install wasm-pack --locked     # --locked: newer deps need a newer rustc
wasm-pack build keel-wasm --target nodejs --out-dir pkg
```

## What is not here yet

There is deliberately **no text interpreter and no `interpret` export.** Turning
Forth *source* into execution tokens is the outer interpreter, which is a
`frames` word written in Forth on top of this kernel, and it arrives with M3/M4.
Until then a host drives the kernel directly: look up primitive tokens by name,
`compile` a thread of them, and `run` it.

This means R-H-02 (the wasm keel exports `new`, `interpret`, `push`, `pop`,
`stack`) is **partly** met: `new`, `push`, `pop` and `stack` are live;
`interpret` is absent rather than stubbed, so no caller can mistake a
placeholder for a working interpreter.

```js
const k = new Keel();
k.push(20); k.push(22);
const body = k.compile([Keel.primitive("+"), Keel.primitive("exit")]);
k.run(body);
k.stack();   // [42]
```

## Editor support

[`editors/emacs/`](editors/emacs/) holds an Emacs package for driving the wasm
keel while working through examples.

## Milestones

M2 native keel (this repo) → M3 frames on the native keel, sea-trials layer 0 →
M4 wasm32 + node runner → M5 ClojureScript host. The full sequence and its
gating are in the spec.

## Deterministic simulation harness

`harness/` runs seeded cases against the keel compiled to wasm and against an
independent JavaScript model of the thirteen primitives (written from the
Forth-2012 definitions and the keel's primitive contracts, not from the Rust),
comparing them after every step. A case is a seed: the cells on the data
stack, the bytes `key` reads, a few threads of execution tokens, and the runs
(threads run one after another on the same machine, so a run that errors
leaves its return frames for the next). Each case is also replayed for
determinism: the same case must end in the same fingerprint, and a snapshot
taken mid-run must restore, in the same kernel or a fresh one, to the same end.

```sh
wasm-pack build keel-wasm --target web --out-dir ../harness/pkg --no-typescript
node harness/cli.mjs --cases 2000            # exits 1 on a kernel bug
python3 -m http.server -d harness 8770        # then open http://127.0.0.1:8770/
```

The page shows outcomes and divergence classes for a range of seeds, and for
any case a step scrubber with the keel and the model side by side, the thread
with the current token marked, and a shrinker. `#seed=1&cases=500` in the URL
reruns a range.

Divergence classes:

| class         | meaning                                                         | kind          |
|---|---|---|
| `state`       | registers, a stack or output differ after a successful step     | kernel bug    |
| `memory`      | memory differs at the end                                       | kernel bug    |
| `error-vs-ok` | one side errored, the other did not                             | kernel bug    |
| `replay`      | the same case ended in two different fingerprints               | kernel bug    |
| `restore`     | a restored snapshot did not finish as the straight run did      | kernel bug    |
| `after-error` | both errored, but the keel had already changed the stacks       | spec question |
| `error-kind`  | both errored, with different errors                             | spec question |

Findings so far (seeds 1..2000, no kernel bugs; three planted faults, a
saturating `+`, a lost `um*` carry and an early `exit`, are each caught):

- Errors are not atomic: a primitive that fails has usually popped its
  operands already (`0 ! exit` leaves an empty stack). The spec does not say
  whether a failed primitive may change the stacks.
- `um/mod` checks the divisor before the depth, so `-1 0= um/mod` with too few
  cells reports "divide by zero", not "data stack underflow".
- An error leaves the run flag set, so a snapshot taken after an error cannot
  be told from a live run: restoring it and stepping executes past the error.

