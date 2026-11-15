\ sicp-1-1.fth -- SICP section 1.1 on thirteen primitives
\
\ Open this in keel-forth-mode and evaluate a line at a time with C-c C-c.
\ C-c C-s opens the stack buffer; C-c C-k resets the kernel between examples.
\
\ Every line below has been run against the kernel.  Words the kernel does
\ not have are flagged by font lock and refused by the evaluator, which is
\ the point: this file is a map of how far SICP 1.1 gets on the thirteen
\ primitives, and exactly where it stops.
\
\ Reset the kernel (C-c C-k) before each numbered example: the stack is
\ shared, and these lines leave results on it.


\ --- 1.1.1  Expressions --------------------------------------------------
\
\ Scheme's prefix combination is Forth's postfix.  The operands go on the
\ stack, the operator consumes them.

\ (+ 137 349)  =>  486
137 349 +

\ (+ 21 35 12 7)  =>  75
\ Scheme's variadic + becomes a fold: there is no arity to declare, the
\ stack is the argument list.
21 35 + 12 + 7 +


\ --- 1.1.1  Nesting ------------------------------------------------------
\
\ (+ (* 2 4) (+ 3 5))  =>  16
\
\ The kernel has no `*'.  It has `um*', an unsigned mixed multiply leaving a
\ double-cell product as ( lo hi ).  For a product that fits in one cell the
\ high cell is 0, so `um* +' adds that 0 back in and leaves just the low
\ cell: a single-cell multiply built out of what exists.
2 4 um* + 3 5 + +

\ (* 5 99)  =>  495
5 99 um* +


\ --- Subtraction, which is not a primitive -------------------------------
\
\ (- 1000 334)  =>  666
\
\ There is no `-' and no `negate'.  Two's complement gives negate as
\ `invert' then `1 +', and `invert x' is `nand x x'.  Duplicating the top of
\ stack is `sp@ @': `sp@' pushes the address holding the former top, `@'
\ fetches it.  So `sp@ @ nand 1 +' is negate, and subtraction is
\ negate-then-add.
1000 334 sp@ @ nand 1 + +

\ The same derivation shown on its own:  (- 6 2)  =>  4
6 2 sp@ @ nand 1 + +


\ --- Division, and the shape of um/mod ------------------------------------
\
\ (/ (+ 5 (* 2 4)) (+ 3 (- 6 2)))  =>  13/7, i.e. 1 remainder 6
\
\ `um/mod' is ( ud-lo ud-hi u -- u-rem u-quot ): a double-cell dividend, so
\ push the numerator, then 0 for its high cell, then the divisor.  It leaves
\ remainder below quotient.
5 2 4 um* + + 0 3 6 2 sp@ @ nand 1 + + + um/mod

\ 486 10 /mod  =>  6 48 -- digit extraction, which is how the frames layer
\ will build `.' once it exists.
486 0 10 um/mod


\ --- Logic from one primitive --------------------------------------------
\
\ `nand' is the kernel's only logical primitive.  AND is NAND then INVERT,
\ and INVERT is NAND with itself.
\
\ (logand 3 5)  =>  1
3 5 nand sp@ @ nand

\ (logand 12 10)  =>  8
12 10 nand sp@ @ nand

\ (zerop 0)  =>  -1, Forth's true
0 0=


\ --- Output --------------------------------------------------------------
\
\ `emit' appends one byte to the kernel's output, which the REPL echoes and
\ `keel-eval-line' shows in the echo area.  There is no `."' and no `.':
\ both are frames words.
72 emit 105 emit


\ --- 1.1.4  Compound procedures: where this stops -------------------------
\
\ (define (square x) (* x x))
\
\ This line will NOT run, and the evaluator says why:
\
\     : square sp@ @ um* + ;
\
\ A colon definition needs the outer interpreter -- the text interpreter
\ that reads a name, creates a dictionary header and compiles the rest --
\ and that is a frames word, written in Forth on top of these thirteen
\ primitives.  It does not exist yet; it arrives at milestone M4.
\
\ What does work today is the kernel-level equivalent: compile the thread by
\ hand and call it with `execute'.  From Emacs:
\
\     (keel-reset)
\     (setq square (keel-compile-thread (list 2 0 11 5)))  ; sp@ @ um* +
\     (keel-push 5)
\     (keel-push square)
\     (keel-eval-string "execute")                         ; => 25
\
\ That is a compound procedure in every sense the kernel cares about: a body
\ address, reached through `execute'.  What is missing is only the name and
\ the parser that would bind it -- see examples/sicp-1-1.org, which does
\ exactly this in an Org Babel session.
\
\ Still out of reach for the same reason, with what each needs:
\
\   (define (abs x) (cond ...))   branching: no branch primitive exists.
\                                 The frames layer builds IF by selecting
\                                 between two body addresses arithmetically
\                                 and calling `execute'.
\   (define (factorial n) ...)    recursion: needs a named definition to
\                                 refer to itself.
\   1.1.7 sqrt by Newton's method needs IF, recursion, and a `/' that
\                                 handles signed operands.
\
\ None of that is a limitation of this Emacs package.  It is milestone M4.
