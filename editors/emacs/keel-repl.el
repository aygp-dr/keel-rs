;;; keel-repl.el --- Comint REPL for the keel Forth kernel  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jason Walsh

;; Author: Jason Walsh <jasonwalsh@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, forth, tools
;; URL: https://github.com/aygp-dr/keel-rs

;; This file is not part of GNU Emacs.

;;; Commentary:

;; An interactive buffer for the keel kernel, built on `comint-mode'.
;;
;; The bridge process is the inferior process of the comint buffer, which is
;; what comint is for, but the I/O is JSON rather than a character stream.  So
;; `comint-input-sender' is replaced: instead of writing the line to the
;; process, it hands the line to `keel-eval-string' and this file renders the
;; result.  Nothing is ever written to the process by comint itself.
;;
;; That buys the usual comint conveniences for free --- input history with
;; \\[comint-previous-input], \\[comint-previous-matching-input-from-input],
;; `comint-input-ring' persistence, the prompt as a field, and
;; \\[comint-send-input] semantics --- without pretending the kernel speaks a
;; character protocol it does not speak.
;;
;; Remember what the kernel can do: the primitive-level subset only.  See the
;; Commentary in keel.el.  Typing `2 3 +' works; typing `dup' does not, and
;; says so.

;;; Code:

(require 'comint)
(require 'eldoc)
(require 'keel)

(defcustom keel-repl-buffer-name "*keel*"
  "Name of the keel REPL buffer."
  :type 'string
  :group 'keel)

(defcustom keel-repl-prompt "keel> "
  "Prompt string for the keel REPL."
  :type 'string
  :group 'keel)

(defcustom keel-repl-banner t
  "When non-nil, print a banner naming what the kernel can and cannot do."
  :type 'boolean
  :group 'keel)

(defvar keel-repl-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map comint-mode-map)
    (keymap-set map "C-c C-s" #'keel-show-stack)
    (keymap-set map "C-c C-k" #'keel-reset)
    (keymap-set map "C-c C-d" #'keel-describe-primitive)
    (keymap-set map "C-c C-p" #'keel-list-primitives)
    map)
  "Keymap for `keel-repl-mode'.")

(define-derived-mode keel-repl-mode comint-mode "Keel-REPL"
  "Major mode for interacting with the keel Forth kernel.

Input is not sent to the inferior process as text: it goes through
`keel-eval-string', which parses the primitive-level subset the kernel can
run today and compiles it into threads of execution tokens.

\\{keel-repl-mode-map}"
  (setq-local comint-prompt-regexp (concat "^" (regexp-quote keel-repl-prompt)))
  (setq-local comint-prompt-read-only t)
  (setq-local comint-input-sender #'keel-repl--send)
  (setq-local comint-use-prompt-regexp nil)
  (setq-local comint-process-echoes nil)
  (setq-local completion-at-point-functions (list #'keel-completion-at-point))
  (setq-local eldoc-documentation-functions (list #'keel-eldoc-function))
  (add-hook 'keel-output-functions #'keel-repl--insert-kernel-output))

(defun keel-repl--buffer ()
  "Return the REPL buffer, or nil if it does not exist."
  (get-buffer keel-repl-buffer-name))

(defun keel-repl--insert-at-mark (text &optional face)
  "Insert TEXT before the REPL's process mark, optionally in FACE."
  (let ((buffer (keel-repl--buffer)))
    (when (and buffer text (not (string-empty-p text)))
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (process (get-buffer-process buffer)))
          (save-excursion
            (goto-char (if process (process-mark process) (point-max)))
            (let ((start (point)))
              (insert text)
              (unless (bolp) (insert "\n"))
              (when face
                (add-text-properties start (point) (list 'font-lock-face face))))
            (when process
              (set-marker (process-mark process) (point)))))))))

(defun keel-repl--insert-kernel-output (text)
  "Echo kernel output TEXT into the REPL buffer, if there is one.
Added to `keel-output-functions' by `keel-repl-mode'."
  (keel-repl--insert-at-mark text 'font-lock-string-face))

(defun keel-repl--send (_process line)
  "Evaluate LINE in the kernel and render the outcome in the REPL.
Installed as `comint-input-sender', so the inferior process is never written
to; _PROCESS is accepted only to match that calling convention."
  (if (string-empty-p (string-trim line))
      (keel-repl--prompt)
    (condition-case err
        ;; Kernel output arrives through `keel-output-functions' during the
        ;; call, so it lands above the result line on its own.
        (let* ((result (keel-eval-string line))
               (stack (alist-get 'stack result)))
          (keel-repl--insert-at-mark
           (format "ok  %s" (keel-format-stack stack))
           'font-lock-comment-face)
          (keel-repl--prompt))
      (keel-error
       (keel-repl--insert-at-mark
        (format "error: %s  [stack %s]"
                (nth 0 (cdr err))
                (keel-format-stack (alist-get 'stack (nth 1 (cdr err)))))
        'error)
       (keel-repl--prompt))
      (user-error
       (keel-repl--insert-at-mark (error-message-string err) 'error)
       (keel-repl--prompt))
      (error
       (keel-repl--insert-at-mark (error-message-string err) 'error)
       (keel-repl--prompt)))))

(defun keel-repl--prompt ()
  "Insert a fresh prompt at the end of the REPL buffer.
Goes through `comint-output-filter' when there is a live process, so that the
prompt becomes a proper comint field; falls back to a plain insert when the
kernel has been stopped."
  (let ((buffer (keel-repl--buffer)))
    (when buffer
      (with-current-buffer buffer
        (let ((inhibit-read-only t)
              (process (get-buffer-process buffer)))
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (if (process-live-p process)
              (progn
                (set-marker (process-mark process) (point-max))
                (comint-output-filter process keel-repl-prompt))
            (insert keel-repl-prompt)))))))

(defun keel-repl--banner ()
  "Return the REPL banner text."
  (concat
   (format "keel %s -- a Forth kernel with thirteen primitives\n" keel-version)
   (format "  %s\n" (string-join keel-primitive-names " "))
   (if (keel-interpret-available-p)
       "  text interpreter: available\n"
     (concat
      "  No text interpreter yet: the outer interpreter is a frames word and\n"
      "  arrives at M4.  Today you can type primitive names and decimal\n"
      "  integers, e.g. `2 3 +'.  `dup', `*' and `: name ... ;' do not exist.\n"))
   "  C-c C-s stack   C-c C-k reset   C-c C-p primitives   C-c C-d describe\n"))

;;;###autoload
(defun keel-repl ()
  "Start or switch to the keel REPL.
The kernel is shared with every other keel command in this Emacs session, so
the stack you build here is the stack `keel-show-stack' displays."
  (interactive)
  (let ((buffer (get-buffer-create keel-repl-buffer-name)))
    (unless (comint-check-proc buffer)
      ;; Start the kernel first: a missing artifact must fail with a clear
      ;; message before a half-built REPL buffer exists.
      (keel-start)
      (with-current-buffer buffer
        (keel-repl-mode)
        (let ((process keel--process))
          ;; Adopt the bridge as this buffer's inferior process.  Its filter
          ;; and sentinel stay keel.el's; comint only needs the process for
          ;; `comint-check-proc' and the process mark.
          (set-process-buffer process buffer)
          (set-marker (process-mark process) (point-max)))
        (let ((inhibit-read-only t))
          (when keel-repl-banner
            (insert (keel-repl--banner))))
        (keel-repl--prompt)))
    (pop-to-buffer buffer)))

(provide 'keel-repl)

;;; keel-repl.el ends here
