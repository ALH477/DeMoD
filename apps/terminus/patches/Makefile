# patches/Makefile — compile-check every .dsp in the patch tree
#
# Usage:
#   make check      compile every patch .dsp + demod-faust libs/examples (CI entry)
#   make compile    compile-check every patch .dsp (fast)
#   make faust      compile-check demod-faust library and examples
#   make test        run the demod-faust numerical regression suite
#   make clean      remove build artifacts
#
# The FAUST_LIB_DIR must point to the demod-faust library so patches can
# `library("demod_skill.lib")` / `library("demod_va.lib")`. Default:
#   ../../demod-faust-0.1.0/lib  (sibling checkout)
#
# Override on the command line:
#   make FAUST_LIB_DIR=/path/to/lib check

FAUST       ?= faust
FAUSTFLAGS  ?= -double
# Resolve Faust library directory: explicit override > $DEMOD_FAUST_LIB env > relative path
FAUST_LIB   ?= $(or $(DEMOD_FAUST_LIB),../../demod-faust-0.1.0/lib)
DEMOD_FAUST ?= ../../demod-faust-0.1.0

PATCHES     := $(shell find . -mindepth 2 -name '*.dsp' -not -path './lofi-synth/*')
FAUST_LIBS  := $(wildcard $(FAUST_LIB)/*.lib)
FAUST_EX    := $(wildcard $(DEMOD_FAUST)/examples/*.dsp)
BUILDDIR    := build

.PHONY: check compile patches faust test clean help

help:
	@grep -E '^#   make' Makefile | sed 's/^#   /  /'

# ---- CI entry point -------------------------------------------------------
check: compile faust
	@echo "==> ALL CHECKS PASSED"

# ---- compile every patch .dsp to C (syntax/semantics) --------------------
compile: patches

patches:
	@echo "==> Compile-checking patches (FAUSTFLAGS=$(FAUSTFLAGS))"
	@mkdir -p $(BUILDDIR)
	@fail=0; \
	for f in $(PATCHES); do \
	  if $(FAUST) $(FAUSTFLAGS) -I $(FAUST_LIB) -lang c "$$f" -o $(BUILDDIR)/`basename $$f`.c >/dev/null 2>$(BUILDDIR)/err.log; then \
	    printf "  OK    %s\n" "$$f"; \
	  else \
	    printf "  FAIL  %s\n" "$$f"; sed 's/^/        /' $(BUILDDIR)/err.log; fail=1; \
	  fi; \
	done; \
	[ $$fail -eq 0 ] || { echo "==> PATCH COMPILE FAILED"; exit 1; }
	@echo "==> patches OK"

# ---- compile-check demod-faust library and examples ----------------------
faust:
	@echo "==> Compile-checking demod-faust libs and examples"
	@mkdir -p $(BUILDDIR)
	@fail=0; \
	for f in $(FAUST_LIBS) $(FAUST_EX); do \
	  if $(FAUST) $(FAUSTFLAGS) -I $(FAUST_LIB) -lang c "$$f" -o $(BUILDDIR)/`basename $$f`.c >/dev/null 2>$(BUILDDIR)/err.log; then \
	    printf "  OK    %s\n" "$$f"; \
	  else \
	    printf "  FAIL  %s\n" "$$f"; sed 's/^/        /' $(BUILDDIR)/err.log; fail=1; \
	  fi; \
	done; \
	[ $$fail -eq 0 ] || { echo "==> FAUST COMPILE FAILED"; exit 1; }
	@echo "==> faust OK"

# ---- numerical regression suite (requires python3 + faust + g++) ---------
test:
	@echo "==> Running regression suite"
	@fail=0; \
	for t in $(DEMOD_FAUST)/tests/regression/*.py; do \
	  echo "--- $$t"; \
	  python3 "$$t" || fail=1; \
	done; \
	[ $$fail -eq 0 ] || { echo "==> TESTS FAILED"; exit 1; }
	@echo "==> tests OK"

clean:
	@rm -rf $(BUILDDIR)
	@echo "==> cleaned"