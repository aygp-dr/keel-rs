;;; keel.el --- Drive the keel WebAssembly Forth kernel from Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Jason Walsh

;; Author: Jason Walsh <jasonwalsh@gmail.com>
;; Maintainer: Jason Walsh <jasonwalsh@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, forth, tools
;; URL: https://github.com/aygp-dr/keel-rs

;; This file is not part of GNU Emacs.

;;; Commentary:

;; keel.el drives the `keel-wasm' build of the forth-keel kernel from Emacs:
;; a 32-bit Forth kernel with one linear memory and exactly thirteen
;; primitives --- @ ! sp@ rp@ 0= + nand exit key emit execute um* um/mod.
;;
;; Emacs cannot execute WebAssembly, so a Node helper (`keel-bridge.js')
;; owns the kernel and speaks newline-delimited JSON over stdio.  This file
;; owns the Emacs side: process lifecycle, the request/response protocol, a
;; parser for the subset of Forth the kernel can run today, interactive
;; evaluation commands, and a live stack buffer.
;;
;; WHAT THIS CANNOT DO YET.  The kernel has no outer (text) interpreter.
;; Parsing Forth source is the job of the `frames' layer --- Forth written on
;; top of the thirteen primitives --- which does not exist yet and arrives at
;; milestone M4.  `keel-wasm' deliberately exports no `interpret'.  So you
;; cannot send `: square dup * ;' and have it run: there is no `dup', no `*',
;; and no colon compiler.
;;
;; What you CAN do today is the primitive-level subset: whitespace-separated
;; primitive names and decimal integer literals.  `keel-eval-string' parses
;; that into a program of two step kinds --- push an integer, or compile and
;; run a thread of execution tokens --- and the bridge executes the steps in
;; order.  Anything else is reported as a clear error naming the word.
;;
;; `keel-eval-string' is the single abstraction behind every evaluation
;; command.  When `keel-wasm' grows an `interpret' export, the bridge's
;; `hello' response advertises it under `capabilities' and
;; `keel-eval-string' switches to it; nothing else in this package changes.
;;
;; Entry points: `keel-repl', `keel-eval-region', `keel-eval-line',
;; `keel-eval-buffer', `keel-eval-expression', `keel-load-file',
;; `keel-show-stack', `keel-reset', `keel-restart', `keel-describe-primitive'.
;; See `keel-forth-mode' for the major mode and its keymap.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'thingatpt)

(defgroup keel nil
  "Drive the keel WebAssembly Forth kernel from Emacs."
  :group 'languages
  :prefix "keel-")

(defconst keel-version "0.1.0"
  "Version of the keel Emacs package.")

(defconst keel--source-directory
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory this package was loaded from.
Used to locate `keel-bridge.js' and, by default, the wasm build.")


;;;; Customization

(defcustom keel-node-program "node"
  "Name of or absolute path to the Node executable that runs the bridge.
Node is required because Emacs cannot execute WebAssembly itself."
  :type 'string
  :group 'keel)

(defcustom keel-wasm-package-directory
  (expand-file-name "../../keel-wasm/pkg/" keel--source-directory)
  "Directory holding the `wasm-pack --target nodejs' build of `keel-wasm'.
It must contain `keel_wasm.js' and `keel_wasm_bg.wasm'.  The default
points at `keel-wasm/pkg' in the keel-rs workspace this package ships
inside.  See `keel-build-command' for how to produce it."
  :type 'directory
  :group 'keel)

(defcustom keel-wasm-crate-directory
  (expand-file-name "../../keel-wasm/" keel--source-directory)
  "Directory of the `keel-wasm' crate, used to build the wasm artifact."
  :type 'directory
  :group 'keel)

(defcustom keel-bridge-program
  (expand-file-name "keel-bridge.js" keel--source-directory)
  "Path to the Node bridge script that hosts the kernel."
  :type 'file
  :group 'keel)

(defcustom keel-request-timeout 10.0
  "Seconds to wait for one bridge response before signalling an error."
  :type 'number
  :group 'keel)

(defcustom keel-display-stack-after-eval t
  "When non-nil, refresh a visible stack buffer after each evaluation.
The buffer is never popped up on its own; use \\[keel-show-stack] for that."
  :type 'boolean
  :group 'keel)

(defcustom keel-stack-buffer-name "*keel-stack*"
  "Name of the buffer showing the kernel's data stack."
  :type 'string
  :group 'keel)

(defvar keel-output-functions nil
  "Abnormal hook run with one string argument: newly emitted kernel output.
`keel-repl' adds to this to echo `emit' output into the REPL buffer.")


;;;; The thirteen primitives

(defconst keel-primitives
  '(("@"       0  "( a-addr -- x )"
     "Fetch the cell at A-ADDR.")
    ("!"       1  "( x a-addr -- )"
     "Store X into the cell at A-ADDR.")
    ("sp@"     2  "( -- a-addr )"
     "Address holding the former top of the data stack, so `sp@ @' is DUP.")
    ("rp@"     3  "( -- a-addr )"
     "Address of the top of the return stack.")
    ("0="      4  "( x -- flag )"
     "True (-1) when X is zero, false (0) otherwise.")
    ("+"       5  "( n1 n2 -- n3 )"
     "Sum, wrapping as a fixed-width 32-bit cell does.")
    ("nand"    6  "( x1 x2 -- x3 )"
     "Bitwise NAND.  The kernel's one logical primitive; AND, OR, INVERT and
NEGATE are frames words derived from it.")
    ("exit"    7  "( -- )"
     "Return to the caller, or end the run when this thread began it.")
    ("key"     8  "( -- char )"
     "Next byte of the input buffer, or -1 when it is exhausted.
Fill the buffer with `keel-set-input'.")
    ("emit"    9  "( char -- )"
     "Append CHAR to the kernel's output.")
    ("execute" 10 "( xt -- )"
     "Execute the token XT.  An xt below 13 is a primitive, any other xt is
the body address of a colon definition.")
    ("um*"     11 "( u1 u2 -- ud-lo ud-hi )"
     "Unsigned mixed multiply: a double-cell product, low cell first.")
    ("um/mod"  12 "( ud-lo ud-hi u -- u-rem u-quot )"
     "Unsigned double divide: remainder then quotient."))
  "The thirteen keel primitives: name, execution token, stack effect, doc.
The execution token is the primitive's discriminant in the kernel, fixed by
requirement R-K-01, so this table is usable before a kernel is running --- for
font locking, completion and ElDoc.  `keel-start' checks it against the live
kernel and warns on any drift.")

(defconst keel-primitive-names (mapcar #'car keel-primitives)
  "Names of the thirteen keel primitives, in R-K-01 order.")

(defconst keel--exit-xt 7
  "Execution token of `exit', which terminates every compiled thread.")

(defun keel-primitive-xt (name)
  "Return the execution token of primitive NAME, or nil if there is none."
  (nth 1 (assoc name keel-primitives)))

(defun keel-primitive-stack-effect (name)
  "Return the stack-effect comment of primitive NAME, or nil."
  (nth 2 (assoc name keel-primitives)))

(defun keel-primitive-documentation (name)
  "Return the documentation string of primitive NAME, or nil."
  (nth 3 (assoc name keel-primitives)))


;;;; Process and protocol

(defvar keel--process nil
  "The running bridge process, or nil.")

(defvar keel--pending-input ""
  "Partial response line received from the bridge so far.")

(defvar keel--responses (make-hash-table :test #'eq)
  "Map of in-flight request id to `pending' or the decoded response.")

(defvar keel--next-id 0
  "Counter for request ids.")

(defvar keel--info nil
  "Decoded `hello' payload of the running bridge, or nil.")

(defun keel-build-command ()
  "Return the exact shell command that builds the wasm artifact."
  (format "wasm-pack build %s --target nodejs --out-dir pkg"
          (directory-file-name
           (expand-file-name keel-wasm-crate-directory))))

(defun keel-wasm-module-file ()
  "Return the absolute path of the `keel-wasm' JavaScript entry point."
  (expand-file-name "keel_wasm.js" keel-wasm-package-directory))

(defun keel-available-p ()
  "Return non-nil when a kernel could be started right now.
That means Node is on `exec-path' and the wasm artifact has been built.
Use this to make a test or a conditional feature degrade gracefully."
  (and (or (file-name-absolute-p keel-node-program)
           (executable-find keel-node-program))
       (file-readable-p keel-bridge-program)
       (file-readable-p (keel-wasm-module-file))))

(defun keel--check-prerequisites ()
  "Signal a readable `user-error' unless a kernel can be started."
  (let ((node (if (file-name-absolute-p keel-node-program)
                  (and (file-executable-p keel-node-program) keel-node-program)
                (executable-find keel-node-program))))
    (unless node
      (user-error
       "keel: cannot find Node (%s); set `keel-node-program' to the node executable"
       keel-node-program))
    (unless (file-readable-p keel-bridge-program)
      (user-error
       "keel: bridge script missing: %s; set `keel-bridge-program'"
       keel-bridge-program))
    (unless (file-readable-p (keel-wasm-module-file))
      (user-error
       "keel: no keel-wasm build at %s -- build it with: %s"
       (directory-file-name (expand-file-name keel-wasm-package-directory))
       (keel-build-command)))
    node))

(defun keel--filter (_process chunk)
  "Accumulate CHUNK and decode every complete response line in it."
  (setq keel--pending-input (concat keel--pending-input chunk))
  (while (string-match "\n" keel--pending-input)
    (let ((line (substring keel--pending-input 0 (match-beginning 0))))
      (setq keel--pending-input (substring keel--pending-input (match-end 0)))
      (unless (string-empty-p (string-trim line))
        (keel--accept-response line)))))

(defun keel--accept-response (line)
  "Decode response LINE and file it under its request id."
  (let ((response (condition-case err
                      (json-parse-string line
                                         :object-type 'alist
                                         :array-type 'list
                                         :null-object nil
                                         :false-object nil)
                    (error
                     (list (cons 'id nil)
                           (cons 'ok nil)
                           (cons 'error (format "undecodable bridge response: %s"
                                                (error-message-string err))))))))
    (let ((id (alist-get 'id response)))
      (if (and id (gethash id keel--responses))
          (puthash id response keel--responses)
        ;; Unsolicited or late: nothing is waiting for it.
        (message "keel: unexpected bridge response: %s"
                 (or (alist-get 'error response) line))))))

(defun keel--sentinel (process _event)
  "Note that bridge PROCESS has gone away, and release anything waiting."
  (unless (process-live-p process)
    (when (eq process keel--process)
      (setq keel--process nil
            keel--info nil))
    (maphash (lambda (id value)
               (when (eq value 'pending)
                 (puthash id
                          (list (cons 'id id)
                                (cons 'ok nil)
                                (cons 'error "the keel bridge exited"))
                          keel--responses)))
             keel--responses)))

(defun keel--start-process ()
  "Start the bridge process and return it.  Signal a `user-error' if it fails."
  (let* ((node (keel--check-prerequisites))
         (stderr (generate-new-buffer " *keel-bridge-stderr*"))
         (process
          (condition-case err
              (make-process
               :name "keel-bridge"
               :command (list node keel-bridge-program (keel-wasm-module-file))
               :connection-type 'pipe
               :coding 'utf-8-unix
               :noquery t
               :stderr stderr
               :filter #'keel--filter
               :sentinel #'keel--sentinel)
            (error
             (kill-buffer stderr)
             (user-error "keel: cannot start the bridge: %s"
                         (error-message-string err))))))
    (setq keel--pending-input ""
          keel--process process)
    (clrhash keel--responses)
    ;; The bridge exits non-zero when it cannot load the wasm module; give it a
    ;; moment and report its own complaint rather than a protocol timeout.
    (accept-process-output process 0.3)
    (unless (process-live-p process)
      (let ((complaint (with-current-buffer stderr
                         (string-trim (buffer-string)))))
        (setq keel--process nil)
        (user-error "keel: the bridge failed to start: %s"
                    (if (string-empty-p complaint) "no diagnostic" complaint))))
    process))

(defun keel--ensure-process ()
  "Return a live bridge process, starting and greeting one if need be."
  (if (process-live-p keel--process)
      keel--process
    (let ((process (keel--start-process)))
      (setq keel--info (keel--request '((op . "hello"))))
      (keel--verify-primitives)
      process)))

(defun keel--verify-primitives ()
  "Warn when the live kernel's primitives differ from `keel-primitives'."
  (let ((live (alist-get 'primitives keel--info)))
    (when (and live (not (equal live keel-primitive-names)))
      (display-warning
       'keel
       (format "the running kernel's primitives %S differ from this package's table %S"
               live keel-primitive-names)
       :warning))))

;; Signalled when the kernel refuses an operation.  The error data is
;; (MESSAGE STATE): the kernel's own message, and the state alist that the
;; failure left behind, so a handler can still show the stack.
(define-error 'keel-error "keel kernel error")

(defun keel--request (request)
  "Send REQUEST, an alist, to the bridge and return its decoded value.
Signal an error if the bridge reports a failure or does not answer within
`keel-request-timeout' seconds."
  (let* ((process (if (process-live-p keel--process)
                      keel--process
                    (keel--ensure-process)))
         (id (cl-incf keel--next-id))
         (payload (json-serialize (cons (cons 'id id) request))))
    (puthash id 'pending keel--responses)
    (process-send-string process (concat payload "\n"))
    (let ((deadline (+ (float-time) keel-request-timeout)))
      (while (eq (gethash id keel--responses) 'pending)
        (unless (process-live-p process)
          (remhash id keel--responses)
          (error "keel: the bridge exited while handling `%s'"
                 (alist-get 'op request)))
        (when (> (float-time) deadline)
          (remhash id keel--responses)
          (error "keel: the bridge did not answer `%s' within %s seconds"
                 (alist-get 'op request) keel-request-timeout))
        (accept-process-output process 0.05)))
    (let ((response (gethash id keel--responses)))
      (remhash id keel--responses)
      (let ((value (alist-get 'value response)))
        (keel--announce-output value)
        (if (alist-get 'ok response)
            value
          (signal 'keel-error
                  (list (or (alist-get 'error response) "unknown kernel error")
                        value)))))))

(defun keel--announce-output (value)
  "Run `keel-output-functions' on any kernel output carried by VALUE."
  (let ((output (alist-get 'output value)))
    (when (and (stringp output) (not (string-empty-p output)))
      (run-hook-with-args 'keel-output-functions output))))


;;;; Lifecycle commands

;;;###autoload
(defun keel-start ()
  "Start the keel kernel, and report what is running.
Does nothing if a kernel is already up."
  (interactive)
  (keel--ensure-process)
  (when (called-interactively-p 'interactive)
    (message "keel: kernel up (bridge %s, node %s, %d primitives, interpret: %s)"
             (alist-get 'bridgeVersion keel--info)
             (alist-get 'nodeVersion keel--info)
             (length (alist-get 'primitives keel--info))
             (if (keel-interpret-available-p) "yes" "no (frames layer, M4)")))
  keel--process)

;;;###autoload
(defun keel-stop ()
  "Stop the keel kernel, discarding all of its state."
  (interactive)
  (if (not (process-live-p keel--process))
      (when (called-interactively-p 'interactive)
        (message "keel: no kernel running"))
    (delete-process keel--process)
    (setq keel--process nil
          keel--info nil)
    (when (called-interactively-p 'interactive)
      (message "keel: kernel stopped"))))

;;;###autoload
(defun keel-restart ()
  "Stop and restart the keel kernel.
Unlike `keel-reset' this discards the dictionary along with everything else,
because it is a brand new kernel."
  (interactive)
  (keel-stop)
  (keel-start)
  (keel--refresh-stack-display)
  (message "keel: kernel restarted"))

;;;###autoload
(defun keel-reset ()
  "Clear the kernel's stacks, buffers and output, and rewind the dictionary.
This is the kernel's own `reset': both stacks empty, the input and output
buffers cleared, and HERE rewound to the start of the dictionary, which
invalidates every body address compiled before now."
  (interactive)
  (keel--request '((op . "reset")))
  (keel--refresh-stack-display)
  (when (called-interactively-p 'interactive)
    (message "keel: kernel reset")))

(defun keel-interpret-available-p ()
  "Return non-nil when the running kernel exports a text interpreter.
False for every build up to milestone M4: parsing Forth source is the job of
the `frames' layer, which is Forth written on top of the thirteen primitives
and does not exist yet."
  (and keel--info
       (alist-get 'interpret (alist-get 'capabilities keel--info))
       t))


;;;; Low-level kernel access

(defun keel-push (value)
  "Push integer VALUE onto the kernel's data stack."
  (interactive "nPush: ")
  (keel--request `((op . "push") (value . ,value)))
  (keel--refresh-stack-display))

(defun keel-pop ()
  "Pop the top of the kernel's data stack and return it.
Interactively, show it in the echo area."
  (interactive)
  (let ((value (alist-get 'value (keel--request '((op . "pop"))))))
    (keel--refresh-stack-display)
    (when (called-interactively-p 'interactive)
      (message "keel: popped %s" value))
    value))

(defun keel-stack ()
  "Return the kernel's data stack as a list, bottom first and top last."
  (alist-get 'stack (keel--request '((op . "stack")))))

(defun keel-depth ()
  "Return how many cells are on the kernel's data stack."
  (alist-get 'depth (keel--request '((op . "depth")))))

(defun keel-compile-thread (xts)
  "Compile XTS, a list of execution tokens, and return its body address.
`exit' is appended unless XTS already ends with it.  Each call consumes
dictionary cells permanently until the next `keel-reset'."
  (alist-get 'body (keel--request `((op . "compile")
                                    (xts . ,(vconcat xts))))))

(defun keel-run (body)
  "Run the thread at dictionary address BODY and return the tokens executed."
  (let ((value (keel--request `((op . "run") (body . ,body)))))
    (keel--refresh-stack-display)
    (alist-get 'steps value)))

(defun keel-set-input (text)
  "Make TEXT the bytes that the `key' primitive will read.
This replaces any unread input.  `key' pushes -1 once TEXT is exhausted."
  (interactive "sInput for key: ")
  (keel--request `((op . "setInput") (text . ,text)))
  (when (called-interactively-p 'interactive)
    (message "keel: %d byte(s) of input queued for `key'"
             (string-bytes text))))


;;;; Parsing the subset the kernel can run today

(defun keel--integer-token-p (token)
  "Return non-nil when TOKEN is a decimal integer literal."
  (string-match-p "\\`[-+]?[0-9]+\\'" token))

(defconst keel--cell-min -2147483648 "Smallest value a 32-bit cell holds.")
(defconst keel--cell-max 2147483647 "Largest value a 32-bit cell holds.")

(defun keel-tokenize (text)
  "Split Forth TEXT into a list of words, dropping comments.
`\\' comments run to the end of the line and `( ... )' comments to the
matching `)'; both delimiters must be whitespace-separated words, as in
standard Forth.  Comment stripping is a convenience of this package: the
kernel itself does not parse text at all."
  (let ((tokens nil)
        (position 0)
        (limit (length text)))
    (while (< position limit)
      (if (string-match "\\`[ \t\n\r\f]+" (substring text position))
          (setq position (+ position (match-end 0)))
        (let* ((rest (substring text position))
               (end (if (string-match "[ \t\n\r\f]" rest)
                        (match-beginning 0)
                      (length rest)))
               (token (substring rest 0 end)))
          (setq position (+ position end))
          (cond
           ;; `\' to end of line.
           ((string= token "\\")
            (let ((newline (string-match "\n" text position)))
              (setq position (if newline (1+ newline) limit))))
           ;; `( ... )' to the matching close.
           ((string= token "(")
            (let ((close (string-match ")" text position)))
              (unless close
                (user-error "keel: unterminated `(' comment"))
              (setq position (1+ close))))
           (t (push token tokens))))))
    (nreverse tokens)))

(defun keel-parse-program (text)
  "Parse Forth TEXT into a program the bridge can execute, as a vector.
Each element is one step: (kind \"push\" v N) to push an integer literal, or
\(kind \"thread\" xts [...]) to compile and run a thread of execution tokens.

Only the primitive-level subset exists today: whitespace-separated names of
the thirteen primitives in `keel-primitives', and decimal integer literals.
Literals cannot be compiled into a thread --- the kernel has no literal
primitive --- so they become host pushes, and consecutive primitives are
batched into one thread.  Steps run strictly in order, which is what makes
`2 3 + 4 +' mean what it says.

Signal a `user-error' naming the offending word for anything else, including
colon definitions: those need the outer interpreter from the frames layer."
  (let ((steps nil)
        (thread nil))
    (cl-flet ((flush ()
                (when thread
                  (push `((kind . "thread") (xts . ,(vconcat (nreverse thread))))
                        steps)
                  (setq thread nil))))
      (dolist (token (keel-tokenize text))
        (cond
         ((keel--integer-token-p token)
          (let ((value (string-to-number token)))
            (unless (and (<= keel--cell-min value) (<= value keel--cell-max))
              (user-error "keel: `%s' does not fit in a 32-bit cell" token))
            (flush)
            (push `((kind . "push") (v . ,value)) steps)))
         ((keel-primitive-xt token)
          (push (keel-primitive-xt token) thread))
         ((member token '(":" ";"))
          (user-error
           "keel: colon definitions need the outer interpreter, which is a frames word (M4); today use `keel-compile-thread' to build a thread by hand"))
         (t
          (user-error
           "keel: `%s' is not one of the thirteen keel primitives (%s) and is not an integer; the kernel has no text interpreter yet, so nothing else can run"
           token (string-join keel-primitive-names " ")))))
      (flush))
    (vconcat (nreverse steps))))


;;;; Evaluation

(defun keel-eval-string (text)
  "Evaluate Forth TEXT in the kernel and return the result alist.
The result carries `stack', `depth', `output', `steps' and `threads'.

This is the single abstraction every evaluation command goes through.  Today
it parses TEXT with `keel-parse-program' --- the primitive-level subset only
--- and sends the resulting program to the bridge.  When the kernel grows a
text interpreter (milestone M4, the frames layer), this hands TEXT over
whole instead and the subset restriction disappears."
  (keel-start)
  (if (keel-interpret-available-p)
      (keel--request `((op . "interpret") (text . ,text)))
    (let ((program (keel-parse-program text)))
      (if (zerop (length program))
          ;; Nothing to run; report the stack as it stands.
          (keel--request '((op . "stack")))
        (prog1 (keel--request `((op . "eval") (program . ,program)))
          (keel--refresh-stack-display))))))

(defun keel-format-stack (stack)
  "Format STACK, a list of cells bottom first, the way Forth prints it."
  (if (null stack)
      "<empty>"
    (mapconcat #'number-to-string stack " ")))

(defun keel--format-result (result)
  "Format RESULT, an alist from `keel-eval-string', for the echo area."
  (let ((stack (alist-get 'stack result))
        (output (alist-get 'output result)))
    (concat (if (and output (not (string-empty-p output)))
                (format "%s  " (string-trim-right output "\n"))
              "")
            (format "ok  %s" (keel-format-stack stack)))))

(defun keel--eval-and-report (text)
  "Evaluate TEXT and report the outcome in the echo area.
Kernel errors are reported as messages, not as Lisp backtraces."
  (condition-case err
      (let ((result (keel-eval-string text)))
        (message "%s" (keel--format-result result))
        result)
    (keel-error
     (let ((state (nth 1 (cdr err))))
       (message "keel error: %s  [stack %s]"
                (nth 0 (cdr err))
                (keel-format-stack (alist-get 'stack state))))
     nil)))

;;;###autoload
(defun keel-eval-region (start end)
  "Evaluate the region between START and END in the kernel."
  (interactive "r")
  (keel--eval-and-report (buffer-substring-no-properties start end)))

;;;###autoload
(defun keel-eval-line ()
  "Evaluate the current line in the kernel."
  (interactive)
  (keel--eval-and-report
   (buffer-substring-no-properties (line-beginning-position)
                                   (line-end-position))))

;;;###autoload
(defun keel-eval-buffer ()
  "Evaluate the whole buffer in the kernel."
  (interactive)
  (keel--eval-and-report (buffer-substring-no-properties (point-min) (point-max))))

;;;###autoload
(defun keel-eval-dwim ()
  "Evaluate the region if it is active, otherwise the current line."
  (interactive)
  (if (use-region-p)
      (keel-eval-region (region-beginning) (region-end))
    (keel-eval-line)))

;;;###autoload
(defun keel-eval-expression (text)
  "Prompt for Forth TEXT and evaluate it in the kernel."
  (interactive "sKeel: ")
  (keel--eval-and-report text))

;;;###autoload
(defun keel-load-file (file)
  "Evaluate the contents of FILE in the kernel.
The whole file is parsed before anything runs, so a word the kernel does not
have aborts the load without executing part of it."
  (interactive "fLoad keel file: ")
  (let ((text (with-temp-buffer
                (insert-file-contents file)
                (buffer-substring-no-properties (point-min) (point-max)))))
    (keel--eval-and-report text)))


;;;; The stack buffer

(defvar-keymap keel-stack-mode-map
  :doc "Keymap for `keel-stack-mode'."
  "g" #'keel-refresh-stack
  "r" #'keel-reset)

(define-derived-mode keel-stack-mode special-mode "Keel-Stack"
  "Major mode for the buffer showing the keel data stack.
\\{keel-stack-mode-map}"
  (setq-local truncate-lines t))

(defun keel--stack-buffer ()
  "Return the stack buffer, creating it if necessary."
  (or (get-buffer keel-stack-buffer-name)
      (with-current-buffer (get-buffer-create keel-stack-buffer-name)
        (keel-stack-mode)
        (current-buffer))))

(defun keel--render-stack (stack)
  "Replace the stack buffer's contents with a rendering of STACK."
  (with-current-buffer (keel--stack-buffer)
    (let ((inhibit-read-only t)
          (depth (length stack)))
      (erase-buffer)
      (insert (format "keel data stack -- depth %d\n\n" depth))
      (if (null stack)
          (insert "  <empty>\n")
        ;; Top of stack first: that is how a Forth programmer reads it.
        (let ((index 0))
          (dolist (cell (reverse stack))
            (insert (format "  %-5s %12d  0x%08x%s\n"
                            (if (zerop index) "top" (format "-%d" index))
                            cell
                            (logand cell #xffffffff)
                            (if (and (<= 32 cell) (< cell 127))
                                (format "  %c" cell)
                              "")))
            (setq index (1+ index)))))
      (goto-char (point-min)))))

(defun keel-refresh-stack ()
  "Fetch the kernel's data stack and redraw the stack buffer."
  (interactive)
  (keel--render-stack (keel-stack)))

(defun keel--refresh-stack-display ()
  "Redraw the stack buffer if it exists and auto-refresh is enabled.
Never raises a window of its own, and never lets a failure here mask the
result of whatever the user was actually doing."
  (when (and keel-display-stack-after-eval
             (get-buffer keel-stack-buffer-name)
             (process-live-p keel--process))
    (ignore-errors
      (keel--render-stack
       (alist-get 'stack (keel--request '((op . "stack"))))))))

;;;###autoload
(defun keel-show-stack ()
  "Display the kernel's data stack in a buffer and keep it up to date."
  (interactive)
  (keel-start)
  (keel-refresh-stack)
  (display-buffer (keel--stack-buffer)))


;;;; Describing primitives

;;;###autoload
(defun keel-list-primitives ()
  "Show the thirteen keel primitives with their stack effects."
  (interactive)
  (with-help-window "*keel primitives*"
    (princ "The keel kernel has exactly thirteen primitives.\n")
    (princ "Everything else in Forth -- DUP, SWAP, *, IF, the outer\n")
    (princ "interpreter -- is a frames word, written in Forth on top of\n")
    (princ "these, and does not exist yet (milestone M4).\n\n")
    (princ (format "  %-8s %-3s %s\n" "name" "xt" "stack effect"))
    (princ (format "  %-8s %-3s %s\n" "----" "--" "------------"))
    (dolist (entry keel-primitives)
      (princ (format "  %-8s %-3d %s\n" (nth 0 entry) (nth 1 entry) (nth 2 entry))))))

(defun keel-word-at-point ()
  "Return the Forth word around point, or nil."
  (let ((word (thing-at-point 'symbol t)))
    (and word (substring-no-properties word))))

;;;###autoload
(defun keel-describe-primitive (name)
  "Describe the keel primitive NAME.
Interactively, default to the word at point and complete over the thirteen."
  (interactive
   (let* ((default (let ((word (keel-word-at-point)))
                     (and word (assoc word keel-primitives) word))))
     (list (completing-read (if default
                                (format "Describe primitive (%s): " default)
                              "Describe primitive: ")
                            keel-primitive-names nil t nil nil default))))
  (let ((entry (assoc name keel-primitives)))
    (unless entry
      (user-error "keel: `%s' is not one of the thirteen primitives" name))
    (with-help-window "*keel primitive*"
      (princ (format "%s  %s\n\nexecution token: %d\n\n%s\n"
                     (nth 0 entry) (nth 2 entry) (nth 1 entry) (nth 3 entry))))))

(defun keel-eldoc-function (callback &rest _ignored)
  "Report the stack effect of the primitive at point via CALLBACK.
Suitable for `eldoc-documentation-functions'."
  (let* ((word (keel-word-at-point))
         (entry (and word (assoc word keel-primitives))))
    (when entry
      (funcall callback
               (format "%s  %s" (nth 0 entry) (nth 2 entry))
               :thing (nth 0 entry)
               :face 'font-lock-keyword-face)
      t)))

(defun keel-completion-at-point ()
  "Complete the keel primitive before point.
Suitable for `completion-at-point-functions'."
  (let ((bounds (bounds-of-thing-at-point 'symbol)))
    (when bounds
      (list (car bounds) (cdr bounds) keel-primitive-names
            :annotation-function
            (lambda (candidate) (concat "  " (keel-primitive-stack-effect candidate)))
            :exclusive 'no))))

(provide 'keel)

;;; keel.el ends here
