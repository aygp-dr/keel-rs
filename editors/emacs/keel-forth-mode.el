;;; keel-forth-mode.el --- Major mode for keel-flavoured Forth  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jason Walsh

;; Author: Jason Walsh <jasonwalsh@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, forth, tools
;; URL: https://github.com/aygp-dr/keel-rs

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A deliberately small major mode for Forth source aimed at the keel kernel.
;;
;; The highlighting is honest about what exists: the thirteen primitives are
;; keywords, decimal integers are constants, and any other word is marked with
;; `keel-unknown-word' --- because today it cannot run.  That is the opposite
;; choice from a general Forth grammar, which would cheerfully highlight DUP,
;; IF and CONSTANT in a kernel that has none of them and give the reader a
;; false picture of what will work.
;;
;; `\\' comments and `( ... )' comments are recognised, matching what
;; `keel-tokenize' strips.
;;
;; Evaluation commands come from keel.el; this mode only binds them.

;;; Code:

(require 'keel)
(require 'eldoc)

(declare-function keel-repl "keel-repl" ())

(defface keel-unknown-word
  '((t :inherit font-lock-warning-face :underline (:style wave)))
  "Face for words the keel kernel cannot run yet.
Every Forth word other than the thirteen primitives falls here until the
frames layer lands its outer interpreter (milestone M4)."
  :group 'keel)

(defcustom keel-forth-mode-flag-unknown-words t
  "When non-nil, highlight words the kernel cannot run with `keel-unknown-word'."
  :type 'boolean
  :group 'keel)

(defconst keel-forth-mode--primitive-regexp
  (concat "\\(?:^\\|[ \t]\\)\\("
          (mapconcat #'regexp-quote keel-primitive-names "\\|")
          "\\)\\(?:[ \t]\\|$\\)")
  "Regexp matching one of the thirteen keel primitives as a whole word.
Forth words are whitespace-delimited and may contain punctuation, so this
cannot use `\\_<' and friends.")

(defun keel-forth-mode--match-unknown-word (limit)
  "Font-lock matcher for a word the kernel cannot run, searching up to LIMIT."
  (let ((found nil))
    (while (and (not found)
                (re-search-forward "[^ \t\n\r\f]+" limit t))
      (let ((word (match-string 0)))
        (unless (or (keel-primitive-xt word)
                    (string-match-p "\\`[-+]?[0-9]+\\'" word)
                    (member word '("\\" "(" ")")))
          (setq found t))))
    found))

(defvar keel-forth-mode-font-lock-keywords
  `((,keel-forth-mode--primitive-regexp 1 font-lock-keyword-face)
    ("\\(?:^\\|[ \t]\\)\\([-+]?[0-9]+\\)\\(?:[ \t]\\|$\\)"
     1 font-lock-constant-face)
    (keel-forth-mode--match-unknown-word
     0 (if keel-forth-mode-flag-unknown-words 'keel-unknown-word nil) t))
  "Font-lock keywords for `keel-forth-mode'.
The unknown-word matcher runs last so that primitives and integers win.")

(defvar keel-forth-mode-syntax-table
  (let ((table (make-syntax-table)))
    ;; `\' is a line comment in Forth, not an escape.
    (modify-syntax-entry ?\\ "<" table)
    (modify-syntax-entry ?\n ">" table)
    ;; Most Forth punctuation is part of a word: `0=', `um/mod', `sp@'.
    (dolist (character '(?@ ?! ?= ?+ ?- ?* ?/ ?. ?, ?< ?> ?? ?' ?\; ?: ?#))
      (modify-syntax-entry character "_" table))
    (modify-syntax-entry ?\" "\"" table)
    table)
  "Syntax table for `keel-forth-mode'.")

(defvar-keymap keel-forth-mode-map
  :doc "Keymap for `keel-forth-mode'."
  "C-c C-c" #'keel-eval-dwim
  "C-c C-r" #'keel-eval-region
  "C-c C-b" #'keel-eval-buffer
  "C-c C-e" #'keel-eval-expression
  "C-c C-l" #'keel-load-file
  "C-c C-z" #'keel-repl
  "C-c C-s" #'keel-show-stack
  "C-c C-k" #'keel-reset
  "C-c C-d" #'keel-describe-primitive
  "C-c C-p" #'keel-list-primitives
  "C-c C-i" #'keel-set-input)

;;;###autoload
(define-derived-mode keel-forth-mode prog-mode "Keel-Forth"
  "Major mode for Forth source aimed at the keel kernel.

Only the thirteen keel primitives and decimal integers are highlighted as
runnable; everything else is flagged, because the kernel has no text
interpreter yet.  See `keel-eval-string'.

\\{keel-forth-mode-map}"
  :syntax-table keel-forth-mode-syntax-table
  (setq-local font-lock-defaults '(keel-forth-mode-font-lock-keywords))
  (setq-local comment-start "\\ ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "\\(?:\\\\\\|(\\)[ \t]*")
  (setq-local comment-use-syntax nil)
  (setq-local completion-at-point-functions (list #'keel-completion-at-point))
  (setq-local eldoc-documentation-functions (list #'keel-eldoc-function))
  ;; Forth is case-insensitive in principle, but keel's primitive names are
  ;; matched exactly by the kernel, so keep font lock exact too.
  (setq-local font-lock-keywords-case-fold-search nil))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.fth\\'" . keel-forth-mode))
;;;###autoload
(add-to-list 'auto-mode-alist '("\\.keel\\'" . keel-forth-mode))

(provide 'keel-forth-mode)

;;; keel-forth-mode.el ends here
