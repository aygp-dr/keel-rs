;;; keel-tests.el --- ERT tests for keel.el  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jason Walsh

;; Author: Jason Walsh <jasonwalsh@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, forth, tools
;; URL: https://github.com/aygp-dr/keel-rs

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Run with `gmake test', or:
;;
;;   emacs --batch -Q -L . -l keel-tests.el -f ert-run-tests-batch-and-exit
;;
;; The tests come in two kinds.  Those that only exercise Emacs-side logic ---
;; the tokenizer, the parser, the primitive table, font lock, completion ---
;; always run.  Those that need a live kernel call `keel-tests--require-kernel'
;; first, which skips the test when Node or the wasm artifact is absent, so
;; the suite passes on a machine with no build.

;;; Code:

(require 'ert)
(require 'keel)
(require 'keel-repl)
(require 'keel-forth-mode)
(require 'ob-keel)

(defun keel-tests--require-kernel ()
  "Skip the running test unless a kernel can actually be started."
  (unless (keel-available-p)
    (ert-skip (format "no kernel available; build it with: %s"
                      (keel-build-command)))))

(defmacro keel-tests--with-fresh-kernel (&rest body)
  "Run BODY against a kernel with empty stacks and no leftover output."
  (declare (indent 0) (debug t))
  `(progn
     (keel-tests--require-kernel)
     (keel-start)
     (keel-reset)
     ,@body))


;;;; The primitive table

(ert-deftest keel-test-exactly-thirteen-primitives ()
  "R-K-01: thirteen primitives, in order, with xt equal to the index."
  (should (= 13 (length keel-primitives)))
  (should (equal keel-primitive-names
                 '("@" "!" "sp@" "rp@" "0=" "+" "nand" "exit"
                   "key" "emit" "execute" "um*" "um/mod")))
  (let ((index 0))
    (dolist (entry keel-primitives)
      (should (= index (nth 1 entry)))
      (should (stringp (nth 2 entry)))
      (should (stringp (nth 3 entry)))
      (setq index (1+ index)))))

(ert-deftest keel-test-primitive-lookup ()
  (should (= 5 (keel-primitive-xt "+")))
  (should (= 7 (keel-primitive-xt "exit")))
  (should (= 12 (keel-primitive-xt "um/mod")))
  (should (equal "( n1 n2 -- n3 )" (keel-primitive-stack-effect "+")))
  (should (stringp (keel-primitive-documentation "nand")))
  ;; `dup' is a frames word, not a keel primitive.
  (should-not (keel-primitive-xt "dup"))
  (should-not (keel-primitive-xt "*")))


;;;; Tokenizing

(ert-deftest keel-test-tokenize-splits-on-whitespace ()
  (should (equal '("2" "3" "+") (keel-tokenize "2 3 +")))
  (should (equal '("2" "3" "+") (keel-tokenize "  2\t3\n+  ")))
  (should (equal nil (keel-tokenize "   \n\t  ")))
  (should (equal nil (keel-tokenize ""))))

(ert-deftest keel-test-tokenize-drops-backslash-comments ()
  (should (equal '("2" "3" "+")
                 (keel-tokenize "2 3 \\ add them up\n+")))
  (should (equal '("1") (keel-tokenize "1 \\ trailing comment with no newline"))))

(ert-deftest keel-test-tokenize-drops-paren-comments ()
  (should (equal '("2" "3" "+")
                 (keel-tokenize "2 3 ( n1 n2 -- n3 ) +")))
  (should (equal '("+") (keel-tokenize "( leading ) +")))
  (should-error (keel-tokenize "2 ( never closed") :type 'user-error))

(ert-deftest keel-test-tokenize-keeps-punctuation-words ()
  "Forth words are whitespace-delimited, so `0=' and `um/mod' survive whole."
  (should (equal '("0=" "um/mod" "sp@" "um*")
                 (keel-tokenize "0= um/mod sp@ um*"))))


;;;; Parsing into a program

(ert-deftest keel-test-parse-pushes-and-threads ()
  "Literals become host pushes; consecutive primitives batch into a thread."
  (should (equal [((kind . "push") (v . 2))
                  ((kind . "push") (v . 3))
                  ((kind . "thread") (xts . [5]))]
                 (keel-parse-program "2 3 +"))))

(ert-deftest keel-test-parse-interleaves-strictly ()
  "`2 3 + 4 +' must run the first + before 4 is pushed."
  (should (equal [((kind . "push") (v . 2))
                  ((kind . "push") (v . 3))
                  ((kind . "thread") (xts . [5]))
                  ((kind . "push") (v . 4))
                  ((kind . "thread") (xts . [5]))]
                 (keel-parse-program "2 3 + 4 +"))))

(ert-deftest keel-test-parse-batches-consecutive-primitives ()
  (should (equal [((kind . "thread") (xts . [2 0 5]))]
                 (keel-parse-program "sp@ @ +"))))

(ert-deftest keel-test-parse-accepts-signed-literals ()
  (should (equal [((kind . "push") (v . -1))
                  ((kind . "push") (v . 42))]
                 (keel-parse-program "-1 +42"))))

(ert-deftest keel-test-parse-empty-program ()
  (should (equal [] (keel-parse-program "")))
  (should (equal [] (keel-parse-program "\\ nothing but a comment\n"))))

(ert-deftest keel-test-parse-rejects-frames-words ()
  "A word the kernel does not have must be named in the error, not guessed at."
  (let ((err (should-error (keel-parse-program "2 dup *") :type 'user-error)))
    (should (string-match-p "dup" (error-message-string err)))))

(ert-deftest keel-test-parse-rejects-colon-definitions ()
  "Colon definitions need the outer interpreter, which does not exist yet."
  (let ((err (should-error (keel-parse-program ": square dup * ;")
                           :type 'user-error)))
    (should (string-match-p "outer interpreter" (error-message-string err)))))

(ert-deftest keel-test-parse-rejects-oversized-literals ()
  (should-error (keel-parse-program "2147483648") :type 'user-error)
  (should-error (keel-parse-program "-2147483649") :type 'user-error)
  (should (equal [((kind . "push") (v . 2147483647))]
                 (keel-parse-program "2147483647")))
  (should (equal [((kind . "push") (v . -2147483648))]
                 (keel-parse-program "-2147483648"))))


;;;; Formatting and prerequisites

(ert-deftest keel-test-format-stack ()
  (should (equal "<empty>" (keel-format-stack nil)))
  (should (equal "1 2 3" (keel-format-stack '(1 2 3))))
  (should (equal "-1" (keel-format-stack '(-1)))))

(ert-deftest keel-test-build-command-is-exact ()
  "The error path must be able to tell the user precisely what to run."
  (let ((command (keel-build-command)))
    (should (string-prefix-p "wasm-pack build " command))
    (should (string-match-p "--target nodejs" command))
    (should (string-match-p "--out-dir pkg" command))))

(ert-deftest keel-test-missing-artifact-is-a-user-error ()
  "A missing build must produce a readable message, not a backtrace."
  (let ((keel-wasm-package-directory "/nonexistent/keel/pkg/")
        (keel--process nil))
    (let ((err (should-error (keel--check-prerequisites) :type 'user-error)))
      (should (string-match-p "wasm-pack build" (error-message-string err))))))

(ert-deftest keel-test-missing-node-is-a-user-error ()
  (let ((keel-node-program "definitely-not-a-real-node-binary")
        (keel--process nil))
    (let ((err (should-error (keel--check-prerequisites) :type 'user-error)))
      (should (string-match-p "cannot find Node" (error-message-string err))))))

(ert-deftest keel-test-available-p-does-not-signal ()
  (should (memq (and (keel-available-p) t) '(t nil))))


;;;; Major mode, completion, ElDoc

(ert-deftest keel-test-forth-mode-fontifies-primitives-only ()
  (with-temp-buffer
    (insert "2 3 + dup\n")
    (keel-forth-mode)
    (font-lock-ensure)
    (goto-char (point-min))
    (search-forward "+")
    (should (eq 'font-lock-keyword-face
                (get-text-property (1- (point)) 'face)))
    (goto-char (point-min))
    (search-forward "dup")
    (should (eq 'keel-unknown-word
                (get-text-property (- (point) 2) 'face)))))

(ert-deftest keel-test-completion-at-point-offers-primitives ()
  (with-temp-buffer
    (keel-forth-mode)
    (insert "na")
    (let ((completion (keel-completion-at-point)))
      (should completion)
      (should (member "nand" (nth 2 completion))))))

(ert-deftest keel-test-eldoc-reports-stack-effect ()
  (with-temp-buffer
    (keel-forth-mode)
    (insert "nand")
    (goto-char (1- (point)))
    (let ((reported nil))
      (should (keel-eldoc-function (lambda (text &rest _) (setq reported text))))
      (should (string-match-p "x1 x2 -- x3" reported)))))

(ert-deftest keel-test-forth-mode-keymap-is-bound ()
  (should (eq 'keel-eval-dwim (keymap-lookup keel-forth-mode-map "C-c C-c")))
  (should (eq 'keel-eval-region (keymap-lookup keel-forth-mode-map "C-c C-r")))
  (should (eq 'keel-repl (keymap-lookup keel-forth-mode-map "C-c C-z")))
  (should (eq 'keel-show-stack (keymap-lookup keel-forth-mode-map "C-c C-s"))))


;;;; Against a live kernel

(ert-deftest keel-test-kernel-starts-and-greets ()
  (keel-tests--with-fresh-kernel
    (should (process-live-p keel--process))
    (should (equal keel-primitive-names (alist-get 'primitives keel--info)))
    ;; There is no text interpreter until the frames layer lands (M4).
    (should-not (keel-interpret-available-p))))

(ert-deftest keel-test-eval-adds-two-numbers ()
  (keel-tests--with-fresh-kernel
    (let ((result (keel-eval-string "2 3 +")))
      (should (equal '(5) (alist-get 'stack result)))
      (should (= 1 (alist-get 'depth result))))))

(ert-deftest keel-test-eval-interleaves-pushes-and-runs ()
  "The whole point of the step program: `2 3 + 4 +' is 9, not a stack mess."
  (keel-tests--with-fresh-kernel
    (should (equal '(9) (alist-get 'stack (keel-eval-string "2 3 + 4 +"))))))

(ert-deftest keel-test-sp-fetch-fetch-is-dup ()
  "`sp@ @' duplicates the top of stack, which is how frames will define DUP."
  (keel-tests--with-fresh-kernel
    (should (equal '(7 7) (alist-get 'stack (keel-eval-string "7 sp@ @"))))))

(ert-deftest keel-test-nand-derives-invert ()
  "INVERT is `sp@ @ nand': NAND of a value with itself."
  (keel-tests--with-fresh-kernel
    (should (equal '(-6) (alist-get 'stack (keel-eval-string "5 sp@ @ nand"))))))

(ert-deftest keel-test-zero-equals-pushes-forth-true ()
  (keel-tests--with-fresh-kernel
    (should (equal '(-1) (alist-get 'stack (keel-eval-string "0 0="))))
    (should (equal '(-1 0) (alist-get 'stack (keel-eval-string "1 0="))))))

(ert-deftest keel-test-emit-reaches-the-host-as-output ()
  (keel-tests--with-fresh-kernel
    (let ((result (keel-eval-string "107 emit 101 emit 101 emit 108 emit")))
      (should (equal "keel" (alist-get 'output result)))
      (should (equal nil (alist-get 'stack result))))))

(ert-deftest keel-test-key-reads-queued-input ()
  (keel-tests--with-fresh-kernel
    (keel-set-input "hi")
    (should (equal '(104 105 -1) (alist-get 'stack (keel-eval-string "key key key"))))))

(ert-deftest keel-test-um-star-gives-a-double-cell-product ()
  (keel-tests--with-fresh-kernel
    ;; 65536 * 65536 = 2^32, so the low cell is 0 and the high cell is 1.
    (should (equal '(0 1) (alist-get 'stack (keel-eval-string "65536 65536 um*"))))))

(ert-deftest keel-test-underflow-signals-keel-error-with-state ()
  (keel-tests--with-fresh-kernel
    (let ((err (should-error (keel-eval-string "+") :type 'keel-error)))
      (should (string-match-p "underflow" (nth 1 err)))
      ;; The failing state comes back too, so the UI can show the stack.
      (should (alist-get 'depth (nth 2 err))))))

(ert-deftest keel-test-reset-clears-the-stack-and-output ()
  (keel-tests--with-fresh-kernel
    (keel-eval-string "1 2 3")
    (should (= 3 (keel-depth)))
    (keel-reset)
    (should (= 0 (keel-depth)))
    (should (equal nil (keel-stack)))))

(ert-deftest keel-test-compile-and-run-a-thread-by-hand ()
  (keel-tests--with-fresh-kernel
    (let ((body (keel-compile-thread (list (keel-primitive-xt "+")))))
      (should (integerp body))
      (keel-push 20)
      (keel-push 22)
      (should (= 2 (keel-run body)))
      (should (equal '(42) (keel-stack))))))

(ert-deftest keel-test-execute-runs-a-compiled-body ()
  "`execute' takes a body address as readily as a primitive xt."
  (keel-tests--with-fresh-kernel
    (let ((body (keel-compile-thread (list (keel-primitive-xt "+")))))
      (keel-push 1)
      (keel-push 2)
      (keel-push body)
      (should (equal '(3) (alist-get 'stack (keel-eval-string "execute")))))))

(ert-deftest keel-test-pop-returns-the-top-cell ()
  (keel-tests--with-fresh-kernel
    (keel-eval-string "11 22")
    (should (= 22 (keel-pop)))
    (should (equal '(11) (keel-stack)))))

(ert-deftest keel-test-stack-buffer-renders-the-stack ()
  (keel-tests--with-fresh-kernel
    (unwind-protect
        (progn
          (keel-eval-string "65 66")
          (keel-refresh-stack)
          (with-current-buffer keel-stack-buffer-name
            (let ((text (buffer-string)))
              (should (string-match-p "depth 2" text))
              (should (string-match-p "top" text))
              ;; Printable cells are annotated with their character.
              (should (string-match-p "66" text)))))
      (when (get-buffer keel-stack-buffer-name)
        (kill-buffer keel-stack-buffer-name)))))

(ert-deftest keel-test-load-file-evaluates-a-file ()
  (keel-tests--with-fresh-kernel
    (let ((file (make-temp-file "keel-test" nil ".fth"
                                "\\ a comment\n2 3 +\n4 +\n")))
      (unwind-protect
          (progn
            (keel-load-file file)
            (should (equal '(9) (keel-stack))))
        (delete-file file)))))

(ert-deftest keel-test-repl-evaluates-input ()
  (keel-tests--with-fresh-kernel
    (unwind-protect
        (progn
          (keel-repl)
          (with-current-buffer keel-repl-buffer-name
            (should (derived-mode-p 'keel-repl-mode))
            (should (eq #'keel-repl--send comint-input-sender))
            (goto-char (point-max))
            (insert "2 3 +")
            (comint-send-input)
            (let ((text (buffer-string)))
              (should (string-match-p "ok  5" text)))
            ;; Kernel output is echoed into the buffer too.
            (goto-char (point-max))
            (insert "107 emit")
            (comint-send-input)
            (should (string-match-p "k" (buffer-string)))
            ;; An unrunnable word reports itself rather than erroring out.
            (goto-char (point-max))
            (insert "dup")
            (comint-send-input)
            (should (string-match-p "dup" (buffer-string)))))
      (when (get-buffer keel-repl-buffer-name)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer keel-repl-buffer-name)))
      ;; The REPL adopted the bridge process, so start over cleanly.
      (keel-stop))))

(ert-deftest keel-test-org-babel-block-returns-the-stack ()
  (keel-tests--with-fresh-kernel
    (should (equal '(5) (org-babel-execute:keel "2 3 +" '((:result-params)))))
    (should (equal "k" (org-babel-execute:keel
                        "107 emit"
                        '((:result-params "output") (:reset . "yes")))))))

(ert-deftest keel-test-org-babel-reports-unrunnable-words ()
  (keel-tests--with-fresh-kernel
    (should-error (org-babel-execute:keel "dup" '((:result-params)))
                  :type 'user-error)))

(provide 'keel-tests)

;;; keel-tests.el ends here
