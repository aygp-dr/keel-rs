;;; ob-keel.el --- Org Babel support for the keel Forth kernel  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jason Walsh

;; Author: Jason Walsh <jasonwalsh@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, forth, literate, tools
;; URL: https://github.com/aygp-dr/keel-rs

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Org Babel backend for `keel' source blocks, so an Org file can be a
;; literate session against the kernel:
;;
;;     #+begin_src keel
;;       2 3 +
;;     #+end_src
;;
;; This is the Emacs answer to the WAForth VS Code extension's one real
;; feature, its `.wafnb' notebook.  Org is the notebook Emacs already has, so
;; there is nothing to invent: no serializer, no cell kinds, no JSON file
;; format.
;;
;; One deliberate difference from that extension: its notebook controllers are
;; constructed stateless, so every cell gets a fresh kernel and nothing
;; carries across cells.  Here the kernel is a session that persists for the
;; Emacs session, because a Forth stack you cannot carry between blocks is not
;; much of a Forth stack.  `:results' defaults to the stack after the block.
;;
;; Header arguments:
;;   :results value  (default) the data stack after the block, bottom first
;;   :results output          whatever `emit' wrote during the block
;;   :reset yes               reset the kernel before running the block

;;; Code:

(require 'ob)
(require 'keel)

(defvar org-babel-default-header-args:keel
  '((:results . "value") (:exports . "both"))
  "Default header arguments for keel source blocks.")

(defconst org-babel-header-args:keel
  '((reset . ((yes no))))
  "Keel-specific header arguments.
`:reset yes' clears the kernel's stacks, buffers and dictionary before the
block runs.")

;; Org looks for this to decide whether a language needs a tangle extension.
(defvar org-babel-tangle-lang-exts)
(add-to-list 'org-babel-tangle-lang-exts '("keel" . "fth"))

(defun org-babel-expand-body:keel (body _params)
  "Return BODY unchanged.
Keel blocks are plain Forth text; there is no preamble to splice in and no
variable substitution, because the kernel has no text interpreter to bind a
name with."
  body)

(defun org-babel-execute:keel (body params)
  "Execute a keel source block BODY with PARAMS and return its result.
Signals a readable error, naming the offending word, when the block uses
anything outside the primitive-level subset the kernel can run today."
  (keel-start)
  (when (equal "yes" (cdr (assq :reset params)))
    (keel-reset))
  (let* ((result-params (cdr (assq :result-params params)))
         (result (condition-case err
                     (keel-eval-string body)
                   (keel-error
                    (error "keel: %s (stack %s)"
                           (nth 0 (cdr err))
                           (keel-format-stack
                            (alist-get 'stack (nth 1 (cdr err)))))))))
    (if (member "output" result-params)
        (or (alist-get 'output result) "")
      ;; `value': the data stack, bottom first, as a list Org can table.
      (alist-get 'stack result))))

(defun org-babel-prep-session:keel (_session _params)
  "Signal that keel has no separate Babel sessions.
There is exactly one kernel per Emacs session, shared by every keel block,
`keel-repl' and every `keel-eval-' command.  Use `:reset yes' to start a
block from a clean stack."
  (user-error "keel: there is one shared kernel; use `:reset yes', or M-x keel-restart"))

(provide 'ob-keel)

;;; ob-keel.el ends here
