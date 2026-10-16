EMACS ?= emacs

.PHONY: check test byte-compile

check: byte-compile test

test:
	$(EMACS) -Q --batch -L . -l test/advpl-compile-test.el -f ert-run-tests-batch-and-exit

byte-compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile advpl-compile.el test/advpl-compile-test.el
	@rm -f advpl-compile.elc test/advpl-compile-test.elc
