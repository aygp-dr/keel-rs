# Makefile for the keel Emacs package.  GNU make syntax; use gmake on FreeBSD.

EMACS      ?= emacs
NODE       ?= node
WASM_PACK  ?= wasm-pack

# This directory, and the keel-rs workspace it lives inside.
HERE       := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
WORKSPACE  := $(abspath $(HERE)../..)
WASM_CRATE := $(WORKSPACE)/keel-wasm
WASM_PKG   := $(WASM_CRATE)/pkg
WASM_GLUE  := $(WASM_PKG)/keel_wasm.js

EL         := keel.el keel-forth-mode.el keel-repl.el ob-keel.el
TEST_EL    := keel-tests.el
ELC        := $(EL:.el=.elc) $(TEST_EL:.el=.elc)
BATCH      := $(EMACS) --batch -Q -L .

.PHONY: all test compile check-warnings lint wasm clean help

all: compile

help:
	@echo 'Targets:'
	@echo '  test            run the ERT suite (kernel tests skip if unbuilt)'
	@echo '  compile         byte-compile, failing on any warning'
	@echo '  wasm            build the keel-wasm artifact the bridge needs'
	@echo '  lint            check the Node bridge parses'
	@echo '  clean           remove .elc files'

# Byte-compile with warnings promoted to failures: the package must compile
# clean, so a warning is a build break.
compile:
	rm -f $(ELC)
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	         -f batch-byte-compile $(EL) $(TEST_EL)
	@# The suite is loaded from source by `test', so leave no stale .elc
	@# of it behind to shadow an edit.
	rm -f $(TEST_EL:.el=.elc)

# Tests that need a live kernel call `ert-skip' when the wasm artifact or Node
# is missing, so this target passes on a machine with no build.
test:
	$(BATCH) -l keel-tests.el -f ert-run-tests-batch-and-exit

check-warnings: compile

lint:
	$(NODE) --check keel-bridge.js

# Build the artifact the bridge loads.  Needs network only the first time, to
# fetch the wasm-bindgen CLI into wasm-pack's cache.
wasm:
	$(WASM_PACK) build $(WASM_CRATE) --target nodejs --out-dir pkg
	@test -f $(WASM_GLUE) && echo "built $(WASM_GLUE)"

clean:
	rm -f $(ELC)
