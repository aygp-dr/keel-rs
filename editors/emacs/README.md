# keel.el — drive the keel WebAssembly Forth kernel from Emacs

An Emacs package for working against the `keel-wasm` build of the
[forth-keel](https://github.com/aygp-dr/forth-keel) kernel: a 32-bit Forth
kernel with one linear byte-addressed memory and **exactly thirteen
primitives**.

```
@  !  sp@  rp@  0=  +  nand  exit  key  emit  execute  um*  um/mod
```

It gives you a comint REPL, evaluate-region/line/buffer commands, a live
stack buffer, a major mode that highlights only what can actually run, ElDoc
stack effects, completion over the thirteen, and an Org Babel backend so an
Org file can be a literate session against the kernel. The
`examples/` directory works SICP section 1.1 as far as thirteen primitives
reach, and says precisely where it stops.

## What it cannot do yet, and why

**There is no text interpreter.** This is the single most important thing to
understand before using the package.

Parsing Forth source — reading a word, looking it up, compiling or executing
it — is the job of the *outer interpreter*. In forth-keel the outer
interpreter is not part of the kernel: it is a `frames` word, written in Forth
on top of the thirteen primitives, and it arrives at milestone **M4**. It does
not exist yet, and `keel-wasm` deliberately exports no `interpret` to pretend
otherwise. The JS-visible API is exactly:

```
new Keel()  push(value)  pop()  stack()  depth()  compile(xts)  run(body)
setInput(text)  output()  reset()      Keel.primitive(name)  Keel.primitiveNames()
```

So you **cannot** type `: square dup * ;` and have it run. There is no `dup`,
no `*`, and no colon compiler. Try it and you get:

```
keel: colon definitions need the outer interpreter, which is a frames word
(M4); today use `keel-compile-thread' to build a thread by hand
```

What you **can** do today is the primitive-level subset:

* whitespace-separated names of the thirteen primitives,
* decimal integer literals (anything that fits in a 32-bit cell),
* `\` line comments and `( ... )` comments, which this package strips —
  the kernel never sees them.

`keel-eval-string` parses that into a *program* of two step kinds and the Node
bridge executes the steps strictly in order:

| step | meaning |
|---|---|
| `push N` | push an integer from the host |
| `thread [xt …]` | `compile` those xts with `exit` appended, then `run` the body |

Literals become host pushes rather than compiled tokens because **the kernel
has no literal primitive** — there is no `lit`, so a number cannot be put into
a thread at all. Consecutive primitives are batched into one thread, and a
literal flushes the thread first. That ordering is what makes `2 3 + 4 +`
mean 9 rather than leaving a mess: push 2, push 3, run `[+]`, push 4, run
`[+]`.

Anything outside the subset is refused with a `user-error` naming the
offending word. Nothing guesses, and nothing silently does the wrong thing.

### How a real REPL drops in

Every evaluation command in the package goes through one function,
`keel-eval-string`. It branches on `keel-interpret-available-p`, which reads
the `capabilities.interpret` flag out of the bridge's `hello` response; the
bridge computes that flag as `typeof vm.interpret === "function"` against the
live wasm object. When `keel-wasm` grows an `interpret` export,
`keel-eval-string` starts handing the text over whole, the subset restriction
disappears, and no other part of this package — not the REPL, not the major
mode, not `ob-keel`, not `keel-load-file` — changes. The `interpret` op
already exists in the bridge and already reports its own absence.

### What SICP 1.1 looks like on thirteen primitives

Every line below was run against the kernel; see `examples/sicp-1-1.fth` and
`examples/sicp-1-1.org`.

| SICP | keel |
|---|---|
| `(+ 137 349)` → 486 | `137 349 +` |
| `(+ 21 35 12 7)` → 75 | `21 35 + 12 + 7 +` |
| `(+ (* 2 4) (+ 3 5))` → 16 | `2 4 um* + 3 5 + +` |
| `(- 1000 334)` → 666 | `1000 334 sp@ @ nand 1 + +` |
| `(/ 13 7)` → 1 r 6 | `13 0 7 um/mod` |
| `(logand 12 10)` → 8 | `12 10 nand sp@ @ nand` |

There is no `*`: `um*` leaves a double-cell product `( lo hi )`, and for a
product that fits in one cell the high cell is zero, so `um* +` adds that zero
back and leaves the low cell. There is no `dup`: `sp@` pushes the address
holding the former top of stack, so `sp@ @` duplicates it. There is no
`negate`: `sp@ @ nand` inverts and `1 +` completes the two's complement.

`(define (square x) (* x x))` stops at the name. The *procedure* is reachable
today — compile the thread and call it through `execute`:

```elisp
(keel-reset)
(let ((square (keel-compile-thread (list 2 0 11 5))))  ; sp@ @ um* +
  (keel-push 5)
  (keel-push square)
  (keel-eval-string "execute"))                        ; => stack (25)
```

What is missing is only the name and the parser that would bind it. Branching,
recursion and `sqrt` need more: see the table at the end of
`examples/sicp-1-1.org`.

## The bridge: a Node helper speaking NDJSON over stdio

Emacs cannot execute WebAssembly, so something else has to own the kernel.

**Decision: a long-lived Node child process holding one `Keel` instance,
speaking newline-delimited JSON over stdin/stdout to an Emacs process
filter.** `keel-bridge.js` is that process; it is ~260 lines and has no
dependencies beyond the generated `keel_wasm.js`.

```
Emacs  --- {"id":2,"op":"eval","program":[…]}\n --->  node keel-bridge.js
       <-- {"id":2,"ok":true,"value":{"stack":[5],…}}\n
```

Why this shape:

* **It is the only option that keeps kernel state.** The kernel's whole point
  is a stack, a dictionary and HERE that persist. A fresh `node -e …` per
  command would reset all of it; a long-lived process is the kernel session.
  This is also why `comint` fits: the bridge genuinely *is* an inferior
  process, which is what comint is for.
* **One line in, one line out, correlated by `id`.** Requests are synchronous
  from Emacs' point of view (`accept-process-output` until the id lands, with
  a `keel-request-timeout` bound), so command code reads straightforwardly,
  but the transport is still async and a dead process or a slow reply fails
  with a message rather than hanging Emacs forever.
* **No sockets, no ports, no temp files, no network.** stdio is the one IPC
  mechanism that needs no configuration and no cleanup.
* **JSON because Emacs 28+ has `json-parse-string` and `json-serialize` in C.**
  No parser to write, no dependency to declare.
* **Errors cross as data, not as exits.** A keel error arrives from wasm as a
  bare string (not an `Error`), so the bridge normalises it and replies
  `{"ok":false,"error":"data stack underflow","value":{…state after the
  failure…}}`. Emacs turns that into a `keel-error` signal carrying the
  message *and* the stack as it stands, which is what lets the REPL print
  `error: data stack underflow  [stack <empty>]` instead of a backtrace.
* **The bridge stays dumb about Forth.** Parsing lives in Emacs
  (`keel-parse-program`), so a bad word is reported in Emacs' own voice,
  naming the word, before anything is sent. The bridge only knows "push" and
  "compile and run these tokens".

Alternatives considered and rejected:

* **A Rust CLI host (`keel-cli`) instead of wasm.** Would avoid Node
  entirely — but the brief is to drive the *WebAssembly* kernel, and this
  package is meant to exercise the same artifact a browser host would. No such
  binary exists in the workspace either.
* **Emacs' own wasm support.** There isn't any.
* **Dynamic module (`.so`) wrapping wasmtime.** Needs a C toolchain, a
  per-platform build, and `--with-modules`; vastly more fragile than `node`
  for no gain.
* **One `node -e` invocation per evaluation.** Loses all kernel state. Fatal.
* **A socket or HTTP server.** Port allocation, lifecycle and security
  problems in exchange for nothing stdio doesn't already do.

### Degrading when things are missing

`keel-available-p` is the predicate; `keel--check-prerequisites` is the error
path, and it signals `user-error` (no backtrace) with the exact fix:

```
keel: no keel-wasm build at /…/keel-rs/keel-wasm/pkg -- build it with: wasm-pack build /…/keel-rs/keel-wasm --target nodejs --out-dir pkg
```

```
keel: cannot find Node (node); set `keel-node-program' to the node executable
```

If the bridge starts but dies — a corrupt or wrong-target artifact, say — its
stderr is captured and reported as `keel: the bridge failed to start: …` with
Node's own complaint, rather than a protocol timeout.

Runtime is fully offline: `keel_wasm.js` reads `keel_wasm_bg.wasm` off disk
with `fs.readFileSync` and instantiates it synchronously. Nothing is fetched.

## Install

Requires Emacs 29.1+ and Node. Tested on FreeBSD 15.1 with Emacs 30.2 and
Node v24.14.1.

```elisp
(add-to-list 'load-path "/path/to/keel-rs/editors/emacs")
(require 'keel)
(require 'keel-forth-mode)   ; major mode for .fth / .keel
(require 'keel-repl)         ; M-x keel-repl
(require 'ob-keel)           ; Org Babel `keel' blocks
```

The defaults locate the bridge and the wasm build relative to the package
directory, so inside this workspace nothing needs configuring. Elsewhere:

```elisp
(setq keel-wasm-package-directory "/path/to/keel-rs/keel-wasm/pkg/"
      keel-node-program "/usr/local/bin/node")
```

## Build the wasm artifact

The package needs a `wasm-pack --target nodejs` build, which produces the
CommonJS glue (`keel_wasm.js`, using `require('fs')` and `__dirname`) that the
bridge loads. Raw `cargo build --target wasm32-unknown-unknown` output is
**not** usable: it has no wasm-bindgen glue, so `Keel` is not reachable from
JS.

```sh
wasm-pack build /path/to/keel-rs/keel-wasm --target nodejs --out-dir pkg
```

or, from this directory, `gmake wasm`. Either produces
`keel-wasm/pkg/keel_wasm.js` plus `keel_wasm_bg.wasm`. `M-x keel-start` prints
this command for you if the artifact is missing, and `keel-build-command`
returns it.

**This works on FreeBSD 15.1 and was verified here** (wasm-pack 0.14.0,
`wasm-opt` from the `binaryen` package, 0.65 s). Two caveats:

* `pkg/` is generated and gitignored (wasm-pack writes a `.gitignore`
  containing `*`), so a fresh clone has no artifact and you must run the build.
* wasm-pack fetches the `wasm-bindgen` CLI into `~/.cache/.wasm-pack/` on
  first use, which needs network. Once cached (here:
  `wasm-bindgen-cargo-install-0.2.130`) rebuilds are offline and sub-second.
  If that first fetch cannot reach the network, the build fails — there is no
  `wasm-bindgen` CLI in `$PATH` on this machine and no `rustup` to install one.

## Commands and keybindings

`keel-forth-mode-map` (also mostly on `keel-repl-mode-map`):

| key | command |
|---|---|
| `C-c C-c` | `keel-eval-dwim` — region if active, else the current line |
| `C-c C-r` | `keel-eval-region` |
| `C-c C-b` | `keel-eval-buffer` |
| `C-c C-e` | `keel-eval-expression` — prompt in the minibuffer |
| `C-c C-l` | `keel-load-file` |
| `C-c C-z` | `keel-repl` |
| `C-c C-s` | `keel-show-stack` |
| `C-c C-k` | `keel-reset` |
| `C-c C-d` | `keel-describe-primitive` |
| `C-c C-p` | `keel-list-primitives` |
| `C-c C-i` | `keel-set-input` — queue bytes for `key` |

Not bound by default: `keel-start`, `keel-stop`, `keel-restart`,
`keel-refresh-stack`, and the programmatic API `keel-push`, `keel-pop`,
`keel-stack`, `keel-depth`, `keel-compile-thread`, `keel-run`,
`keel-eval-string`.

`keel-reset` is the kernel's own reset: both stacks emptied, input and output
buffers cleared, and HERE rewound to the start of the dictionary — **which
invalidates every body address compiled before it**. `keel-restart` replaces
the process outright.

There is exactly one kernel per Emacs session, shared by the REPL, every
`keel-eval-` command and every Org Babel block. The stack you build in the
REPL is the stack `keel-show-stack` displays.

### The REPL

`keel-repl` derives from `comint-mode` and adopts the bridge process as the
buffer's inferior process, but replaces `comint-input-sender`: input is never
written to the process as text, it goes to `keel-eval-string` and the result
is rendered into the buffer. That buys input history, `M-p`, prompt fields and
the rest of comint without pretending the kernel speaks a character protocol
it does not speak. `emit` output is echoed into the buffer through
`keel-output-functions` and appears above the `ok` line.

### The major mode

`keel-forth-mode` highlights the thirteen primitives as keywords, decimal
integers as constants, and **every other word with `keel-unknown-word`** (wavy
underline), because today it cannot run. Set
`keel-forth-mode-flag-unknown-words` to nil to turn that off.

### Org Babel

```org
#+begin_src keel :reset yes
  2 3 +
#+end_src

#+RESULTS:
| 5 |
```

`:results value` (the default) gives the data stack bottom-first, so a result
is always a table row. `:results output` gives what `emit` wrote. `:reset yes`
clears the kernel before the block. There are no Babel `:session`s — there is
one kernel, which is the point.

## What was taken from the WAForth VS Code extension, and what was not

The reference named for this work was
[`remko.waforth-vscode-extension`](https://marketplace.visualstudio.com/items?itemName=remko.waforth-vscode-extension),
the VS Code extension for [WAForth](https://github.com/remko/waforth), Remko
Tronçon's WebAssembly Forth.

**First, a correction worth recording.** That extension is far smaller than
its reputation suggests. Reading its `package.json` `contributes` section and
`extension.ts` (v0.1.10): it has **one** command, `waforth-notebook.new`
("WAForth: New Notebook"), **no keybindings at all**, no REPL, no terminal, no
webview, no output channel and no stack view. Its entire surface is a notebook
serializer for `.wafnb` files plus two notebook controllers ("WAForth" and
"Thurtle"), a `waforth` language id, and a TextMate grammar. Several things
one might assume to "mirror" simply are not there, so they could not be taken.

### Taken

| From WAForth | Here | Why |
|---|---|---|
| The notebook (`.wafnb`), its one real feature | `ob-keel.el` — Org Babel `keel` blocks | Org *is* the notebook Emacs already has. Literate Forth against a live kernel is exactly the interaction that extension offers, and it suits working through SICP. |
| A language id + grammar for Forth | `keel-forth-mode` | Editing Forth wants a major mode. But see "Rejected" on the grammar itself. |
| `withLineBuffer` — buffer `onEmit` into lines before showing it | Line-oriented output echoed into the REPL via `keel-output-functions` | Character-at-a-time output in an Emacs buffer is unusable. |
| `read(s)` — push text into the input buffer without interpreting | `keel-set-input` for the `key` primitive | Same need, and keel's `key`/`setInput` pair maps directly. |
| `ErrorCode` / `isSuccess` — errors as values, surfaced in the UI | `keel-error` carrying message *and* post-failure stack; `user-error` for unrunnable input | Same principle: a Forth error is a normal outcome to display, not a crash. |
| Instantiating the wasm synchronously at load, with no runtime fetch | `keel_wasm.js` + `fs.readFileSync` in the bridge | Offline operation. WAForth inlines the binary into its bundle at build time; we read it off disk. Same guarantee. |

### Rejected

| From WAForth | Why not |
|---|---|
| The `.wafnb` JSON notebook format and its serializer | Inventing a JSON notebook file format for Emacs when Org exists would be pure loss. Org files are already literate, already version-controllable, already exportable. |
| **Stateless cell execution** | This is a deliberate *inversion*, not an omission. Both of that extension's controllers are constructed with `stateful=false`, so each cell builds a fresh `new WAForth()` and nothing carries between cells (its `globalForth` stateful path exists but is unreachable as called). For keel that would be wrong: with no outer interpreter, the stack and the dictionary *are* the program state, and a stack you cannot carry between blocks is not much of a stack. One kernel per Emacs session, `:reset yes` when you want a clean one. |
| The TextMate grammar (`waforth.tmGrammar.json`) | It is a Gforth-flavoured grammar: it highlights `CONSTANT`, `VARIABLE`, `CREATE`, `DEFER`, `I`, `J`, `S"`, `."`, `TRUE`, `BL`, `:NONAME`, hex `$` literals — a hundred-odd words the keel kernel does not have. Porting it would paint a picture of a language that runs, over a kernel that would refuse almost all of it. `keel-forth-mode` inverts the default instead: the thirteen primitives are keywords and *everything else is flagged*, so the highlighting tells you the truth about what will execute. |
| The Thurtle turtle-graphics controller and its SVG output | Needs a host-call mechanism to bind Forth words to JS functions. WAForth has one (`SCALL` plus `bind`/`bindAsync`); `keel-wasm` has no such facility at all — there is no way to call out of the kernel. Nothing to port. |
| `bind` / `bindAsync` / `SCALL` generally | Same reason: no host-call primitive exists in keel. The thirteen do not include one. |
| `pushString` / `popString` / `here()` / `memory()` | Not exported by `keel-wasm`. Memory is reachable only through the `@` and `!` primitives from inside a thread, which `keel-eval-string` already lets you do. |
| `onEmit` as a callback | keel buffers output and the host polls `output()`; there is no callback to register. The bridge diffs the cumulative string and reports only the delta, which recovers the same behaviour. |
| The `file/newFile` menu contribution; `.vsix` packaging; the dual node/browser builds; `wafnb2html` | VS Code platform concerns with no Emacs analogue. |
| A "new notebook" command | `C-x C-f foo.org` already does this. Adding `keel-new-notebook` would be a command that does less than `find-file`. |

### Ours, not WAForth's

`keel-show-stack` (a live stack buffer), `keel-describe-primitive` and ElDoc
stack effects, `completion-at-point` over the thirteen, `keel-list-primitives`,
`keel-load-file`, and `keel-compile-thread` / `keel-run` as a user-facing API.
The extension has none of these. The stack buffer and the primitive
documentation matter much more here than they would for WAForth, because with
thirteen primitives and no interpreter you are reasoning about the stack
constantly and the word set is small enough to document exhaustively.

## Development

```sh
gmake compile   # byte-compile; any warning is a build failure
gmake test      # ERT suite
gmake lint      # node --check on the bridge
gmake wasm      # build the artifact
```

`gmake compile` sets `byte-compile-error-on-warn`, so the package must compile
with zero warnings. Tests needing a live kernel call `ert-skip` when Node or
the artifact is absent, so `gmake test` passes on a machine with no build (42
tests; 19 skip without one).

## Files

| file | |
|---|---|
| `keel.el` | core: process, protocol, parser, eval commands, stack buffer, ElDoc, completion |
| `keel-repl.el` | comint REPL |
| `keel-forth-mode.el` | major mode, font lock, keymap |
| `ob-keel.el` | Org Babel backend |
| `keel-bridge.js` | the Node host |
| `keel-tests.el` | ERT suite |
| `examples/sicp-1-1.fth` | SICP 1.1 as evaluable Forth, with a map of where it stops |
| `examples/sicp-1-1.org` | the same as a literate Org Babel session |

## Known limits

* The subset only, until M4. See above.
* Each `thread` step consumes dictionary cells permanently until the next
  `keel-reset`, so a very long REPL session can eventually fill the 64 KiB
  dictionary (`dictionary full`). `keel-reset` or `keel-restart` recovers.
* Requests are synchronous, so a kernel thread that runs long blocks Emacs
  until `keel-request-timeout`. The kernel's own 10-million-token step limit
  bounds a runaway thread and reports `step limit reached`.
* Killing the REPL buffer kills the bridge, and with it the kernel's stack and
  dictionary.
* Literals are decimal only. The kernel's `BASE` is not consulted, because
  reading a number in BASE is the outer interpreter's job.
