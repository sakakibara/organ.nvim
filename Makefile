# organ.nvim development Makefile.
#
# `make test` is the canonical entry point — bootstraps test deps + builds
# the tree-sitter grammar + runs the suite.  Idempotent: re-running is fast.

NVIM      ?= nvim
TEST_DIR  := tests

# Every target builds and loads the grammars from a data dir of its own,
# never the one the developer's Neovim uses.
export XDG_DATA_HOME := $(CURDIR)/$(TEST_DIR)/.tmp/xdg-data
GRAMMAR   := $(XDG_DATA_HOME)/nvim/organ/parser/org.so
DEPS_DIR  := $(TEST_DIR)/deps

.PHONY: help deps demo-deps grammar test test-only test-fold test-behavioral lint lint-md lint-doc clean \
        demos demos-force clean-demos \
        conformance conformance-ids

help:
	@echo "organ.nvim - make targets"
	@echo ""
	@echo "  make test            bootstrap deps + build grammar + run all tests"
	@echo "  make test-only       run tests without re-bootstrapping (fast iteration)"
	@echo "  make test-fold       run only fold-related tests"
	@echo "  make test-behavioral run only tests/behavioral/ (user-perceptible scenarios)"
	@echo "  make deps            fetch test-time deps into tests/deps/ (list in scripts/test-deps.sh)"
	@echo "  make demo-deps       fetch demo-time deps (snacks.nvim, catppuccin) into tests/deps/"
	@echo "  make grammar         build the tree-sitter grammars"
	@echo "  make lint            stylua --check on lua/ plugin/ tests/"
	@echo "  make lint-md         markdownlint-cli2 on **/*.md (CI-enforced)"
	@echo "  make lint-doc        vimhelplint on doc/organ.txt (CI-enforced via test suite)"
	@echo "  make demos           rebuild stale assets/demos/*.gif from assets/tapes/*.tape (incremental)"
	@echo "  make demos-force     remove assets/demos/ + rebuild every GIF (use when an init / theme change should regen all)"
	@echo "  make clean-demos     remove assets/demos/ without rebuilding"
	@echo "    Tip: 'make -j5 demos-force' renders all five tapes in parallel"
	@echo "    (~5x faster).  Each render uses its own chromium instance,"
	@echo "    peak RAM ~1.25GB.  Same flag works with any of the demo targets."
	@echo "  make conformance     run every Emacs conformance gate (tests/conformance/*/gate.lua)"
	@echo "  make conformance-ids PHASES=<path>  check tests/conformance/ids.tsv against phases.tsv"
	@echo "  make clean           remove tests/deps/ (does NOT touch the built grammar)"

# Fetch test-time plugin dependencies (gitignored).  Idempotent.
deps:
	@bash scripts/test-deps.sh

demo-deps:
	@bash scripts/demo-deps.sh

# Fetch + build the pinned tree-sitter grammars into
# $(XDG_DATA_HOME)/nvim/organ/parser/.  Nothing is vendored:
# grammar_install fetches tree-sitter-organ and tree-sitter-organ-inline
# at the revisions it pins and compiles them locally; ORGAN_GRAMMAR_SRC
# builds local checkouts instead (see CONTRIBUTING.md).
grammar:
	@$(NVIM) --clean --headless --cmd "set rtp+=$(PWD)" \
	  -c 'lua local ok, err = require("organ.grammar_install").install(); if not ok then io.stdout:write("grammar install failed: " .. tostring(err) .. "\n"); os.exit(1) end' \
	  -c 'qa' 2>/dev/null
	@test -f "$(GRAMMAR)" || (echo "grammar build failed: $(GRAMMAR) not found" && exit 1)

test: deps grammar test-only

# Walks tests/*_test.lua AND tests/behavioral/*_test.lua, running each
# in a clean nvim --headless invocation.  Reports the failing files at
# the end and exits non-zero if any failed.
# `-k 5` follows the TERM with a KILL: a wedged nvim can ignore TERM, and
# orphaned pairs have outlived their timeout by days, blocking later runs.
# The budget is generous because a parity test spawns emacs once per case
# and legitimately runs for half a minute; it bounds a wedge, not slowness.
test-only:
	@fails=0; failed=""; \
	for t in $(TEST_DIR)/*_test.lua $(TEST_DIR)/behavioral/*_test.lua; do \
	  [ -f "$$t" ] || continue; \
	  printf '\033[2m--- %s\033[0m\n' "$$t"; \
	  if ! timeout -k 5 120 $(NVIM) --headless -l "$$t" </dev/null; then \
	    fails=$$((fails+1)); failed="$$failed $$t"; \
	  fi; \
	done; \
	if [ $$fails -gt 0 ]; then \
	  echo ""; \
	  echo "FAIL: $$fails test file(s) failed:"; \
	  for f in $$failed; do echo "  $$f"; done; \
	  exit 1; \
	fi; \
	echo ""; \
	echo "PASS: all tests green"

test-fold:
	@for t in $(TEST_DIR)/fold_*_test.lua; do \
	  echo "--- $$t"; $(NVIM) --headless -l "$$t" </dev/null || exit 1; \
	done

test-behavioral:
	@for t in $(TEST_DIR)/behavioral/*_test.lua; do \
	  echo "--- $$t"; $(NVIM) --headless -l "$$t" </dev/null || exit 1; \
	done

lint:
	@stylua --check lua/ plugin/ tests/
	@command -v luacheck >/dev/null || { \
	  echo "luacheck not on PATH -- install with: luarocks install luacheck"; \
	  exit 1; }
	@luacheck lua/ plugin/

# Line-coverage report via luacov. Each headless test process loads luacov
# when ORGAN_COVERAGE is set (see tests/_bootstrap.lua); stats accumulate in
# luacov.stats.out across the run, then luacov renders the summary.
test-cov: deps grammar
	@command -v luacov >/dev/null || { \
	  echo "luacov not on PATH -- install with: luarocks install luacov"; \
	  exit 1; }
	@rm -f luacov.stats.out luacov.report.out
	@ORGAN_COVERAGE=1 $(MAKE) test-only >/dev/null 2>&1 || true
	@luacov
	@tail -n 12 luacov.report.out

# Lints the tracked markdown, which is what CI's checkout contains --
# a local tree also holds ignored notes and vendored grammars whose
# style is not this repo's business.  Falls back to `npx` so a checkout
# with node but no global install still lints; CI runs the same rules
# through markdownlint-cli2-action.
lint-md:
	@files=$$(git ls-files '*.md'); \
	if [ -z "$$files" ]; then echo "no tracked markdown"; exit 0; fi; \
	if command -v markdownlint-cli2 >/dev/null; then \
	  markdownlint-cli2 $$files; \
	elif command -v npx >/dev/null; then \
	  npx --yes markdownlint-cli2 $$files; \
	else \
	  echo "markdownlint-cli2 not on PATH and no npx — install one of:"; \
	  echo "  npm install -g markdownlint-cli2"; \
	  echo "  brew install markdownlint-cli2"; \
	  exit 1; \
	fi

lint-doc:
	@test -d $(DEPS_DIR)/vim-vimhelplint || (echo "vim-vimhelplint not in $(DEPS_DIR)/ -- run 'make deps'" && exit 1)
	@$(NVIM) -u NONE -i NONE --headless \
	  --cmd 'set rtp+=$(DEPS_DIR)/vim-vimhelplint' \
	  --cmd 'filetype plugin on' \
	  -c 'edit doc/organ.txt' \
	  -c 'verb VimhelpLintEcho' \
	  -c qa

# Emacs conformance gates: one per area under tests/conformance/.  Each
# renders its whole corpus through Emacs in one batch run, so the budget
# per gate is far above test-only's.
conformance:
	@fails=0; failed=""; ran=0; \
	for g in $(TEST_DIR)/conformance/*/gate.lua; do \
	  [ -f "$$g" ] || continue; \
	  ran=$$((ran+1)); \
	  printf '\033[2m--- %s\033[0m\n' "$$g"; \
	  if ! TZ=UTC LC_ALL=C timeout -k 5 1800 $(NVIM) --headless -l "$$g" </dev/null; then \
	    fails=$$((fails+1)); failed="$$failed $$g"; \
	  fi; \
	done; \
	if [ $$ran -eq 0 ]; then echo "FAIL: no conformance gates found"; exit 1; fi; \
	if [ $$fails -gt 0 ]; then echo "FAIL:$$failed"; exit 1; fi

# ids.tsv is generated outside the repo (the project's phases.tsv, written
# from the conformance inventory); this checks the committed copy is current.
conformance-ids:
	@test -n "$(PHASES)" || (echo "usage: make conformance-ids PHASES=<path to phases.tsv>" && exit 2)
	@cmp -s "$(PHASES)" $(TEST_DIR)/conformance/ids.tsv || \
	  (echo "tests/conformance/ids.tsv differs from $(PHASES); copy it in and review the diff" && exit 1)

# Demos: render each `.tape` script in assets/tapes/ to an animated
# GIF via `vhs`.  Tapes are the source of truth; the rendered GIFs
# are derived artifacts.
#
# CI vs. local split: assets/demos/ is the canonical path that the
# README references and CI publishes to.  Locally, `make demos`
# writes to assets/demo-preview/ instead so a contributor's local
# render can't dirty `git status` for the tracked CI-published file.
# Sibling-dir naming (no leading dot) so the directory shows up in
# regular `ls assets/` and `open assets/` -- contributors are
# supposed to open the previews to verify a tape edit, hiding the
# dir adds friction for no benefit.  The
# .github/workflows/demos.yml job sets CI=true (GitHub Actions does
# this automatically), which flips the output dir to assets/demos/.
DEMO_OUTDIR := $(if $(CI),assets/demos,assets/demo-preview)
DEMO_TAPES  := $(wildcard assets/tapes/*.tape)
DEMO_GIFS   := $(patsubst assets/tapes/%.tape,$(DEMO_OUTDIR)/%.gif,$(DEMO_TAPES))

demos: demo-deps $(DEMO_GIFS)
	@if [ "$(DEMO_OUTDIR)" != "assets/demos" ]; then \
	  echo ""; \
	  echo "Local preview rendered to $(DEMO_OUTDIR)/."; \
	  echo "The canonical assets/demos/*.gif files are written by CI"; \
	  echo "(see .github/workflows/demos.yml) so local renders never"; \
	  echo "show up as dirty in 'git status'.  Open the previews to"; \
	  echo "verify a tape edit before pushing."; \
	fi
	@# Helpful hint when nothing was rebuilt — make's incremental
	@# build skips up-to-date targets silently and the user might
	@# have expected a fresh render.
	@stale=0; \
	for tape in $(DEMO_TAPES); do \
	  gif=$(DEMO_OUTDIR)/$$(basename $${tape%.tape}).gif; \
	  if [ ! -f "$$gif" ] || [ "$$tape" -nt "$$gif" ]; then \
	    stale=1; break; \
	  fi; \
	done; \
	if [ $$stale -eq 0 ]; then \
	  echo ""; \
	  echo "All demo GIFs are up-to-date with their tapes."; \
	  echo "To force regeneration (e.g. after editing minimal_init.lua"; \
	  echo "or pulling a new VHS / catppuccin version):"; \
	  echo "  make demos-force"; \
	fi

# Force-rebuild every GIF.  Useful when something OTHER than a tape
# changed (init.lua, theme version, font) so make's mtime check
# wouldn't trigger a rebuild on its own.
#
# Recipe (not prerequisite chain) so the clean step ALWAYS finishes
# before `make demos` checks any output mtime — under `make -j5`,
# parallel prereqs raced and `demos` would sometimes see still-
# present GIFs as up-to-date and skip rendering.  The sub-$(MAKE)
# inherits MAKEFLAGS so `make -j5 demos-force` still parallelises
# the actual rendering.
demos-force:
	@rm -rf $(DEMO_OUTDIR)
	@echo "removed $(DEMO_OUTDIR)/"
	@$(MAKE) --no-print-directory demos

# Removes both the local-preview dir and the canonical CI dir.
clean-demos:
	@rm -rf assets/demo-preview assets/demos
	@echo "removed assets/demo-preview/ and assets/demos/"

# Pattern rule for whichever output directory is active.  $(@D) is
# auto-extracted from the target path so the rule body doesn't need
# to know whether we're rendering to .demo-preview/ or assets/demos/.
$(DEMO_OUTDIR)/%.gif: assets/tapes/%.tape
	@command -v vhs >/dev/null || { \
	  echo "vhs not on PATH — install one of:"; \
	  echo "  macOS:    brew install vhs"; \
	  echo "  Linux:    use the prebuilt release from"; \
	  echo "            https://github.com/charmbracelet/vhs/releases"; \
	  echo "            (Arch: pacman -S vhs ; Nix: nixpkgs#vhs)"; \
	  echo "  Windows:  scoop install vhs    # or winget install charmbracelet.vhs"; \
	  echo "  any:      go install github.com/charmbracelet/vhs@latest"; \
	  exit 1; }
	@mkdir -p $(@D)
	@# Delete a stale output BEFORE rendering so a silent vhs failure
	@# (e.g. ffmpeg dyld error masked by vhs as exit 0) leaves an
	@# obviously-missing target instead of a misleading old GIF.
	@rm -f $@ $@.log
	@# Inject `Env DEMO_LOG_PATH "<abs>"` into a temp copy of the tape
	@# AFTER the Set/Output directive block (vhs requires Set lines at
	@# the very top — anything before them gets silently ignored, which
	@# blew up width/height/padding/theme on first try) but BEFORE the
	@# first command (Hide/Show/Type/etc.).  awk inserts before the
	@# first non-Set, non-Output, non-blank, non-comment line.
	@# minimal_init.lua reads DEMO_LOG_PATH and writes :messages to
	@# that path on VimLeavePre, giving us a buffer-level error log
	@# we can grep below.
	@# Detect whether `JetBrainsMono Nerd Font Mono` is installed on
	@# this machine.  fc-list works on Linux + macOS (when fontconfig
	@# is present, e.g. via Homebrew); falls back to system_profiler
	@# on macOS.  If the font is absent we skip the FontFamily
	@# directive entirely so vhs uses its built-in JetBrains Mono
	@# (renders cleanly; nerd-font glyphs degrade to tofu but the
	@# rest of the demo is unaffected).
	@font_line=""; \
	if command -v fc-list >/dev/null 2>&1; then \
	  if fc-list 2>/dev/null | grep -qi "JetBrainsMono Nerd Font Mono"; then \
	    font_line='Set FontFamily "JetBrainsMono Nerd Font Mono"'; \
	  fi; \
	elif command -v system_profiler >/dev/null 2>&1; then \
	  if system_profiler SPFontsDataType 2>/dev/null | grep -qi "JetBrainsMono Nerd Font Mono"; then \
	    font_line='Set FontFamily "JetBrainsMono Nerd Font Mono"'; \
	  fi; \
	fi; \
	awk -v env="$$(pwd)/$@.log" -v font_line="$$font_line" ' \
	  /^(Set|Output)([ \t]|$$)/ || /^[ \t]*$$/ || /^[ \t]*#/ { print; next } \
	  !inserted { \
	    if (font_line != "") print font_line; \
	    printf "Env DEMO_LOG_PATH \"%s\"\n", env; \
	    inserted = 1 \
	  } \
	  { print } \
	' $< > $@.tape
	@# `--quiet` suppresses vhs's tape echo + progress output.  Crucial
	@# under `make -j5`: without it, 5 vhs instances print interleaved
	@# OSC color queries + progress lines that look like terminal
	@# corruption.  Capture stdout/stderr into a sidecar log so a real
	@# vhs failure is still recoverable; on non-zero exit we dump the
	@# log so the actual cause is visible (silent failure was bad UX).
	@if ! vhs --quiet $@.tape --output $@ > $@.vhs.log 2>&1; then \
	  echo ""; \
	  echo "ERROR: vhs failed for $@:"; \
	  echo ""; \
	  sed 's/^/  /' $@.vhs.log; \
	  echo ""; \
	  echo "Tape file kept for inspection: $@.tape"; \
	  exit 1; \
	fi
	@rm -f $@.tape
	@# Verify the GIF was actually written.  vhs has been observed
	@# to exit 0 even when ffmpeg crashed mid-encode (libx265 mismatch
	@# after a homebrew upgrade).  Treat a missing or empty output
	@# file as a hard failure with a useful hint.
	@if [ ! -s $@ ]; then \
	  echo ""; \
	  echo "ERROR: $@ was not written (or is empty)."; \
	  echo "VHS likely failed silently — most common cause is an"; \
	  echo "ffmpeg / libx265 ABI mismatch after a homebrew upgrade."; \
	  echo "Try: brew reinstall ffmpeg"; \
	  echo "Re-run 'make demos' after the reinstall completes."; \
	  exit 1; \
	fi
	@# Scan the captured messages for errors / blocking prompts /
	@# "not modifiable" / Lua stacks.  These are problems that DON'T
	@# fail vhs (the GIF still renders; the errors are just visible
	@# inside the recording) so we have to detect them ourselves.
	@# Show 4 lines of context BEFORE each match -- the actual error
	@# message ("E5108: Lua: foo.lua:12: attempt to ...") sits above
	@# the "stack traceback:" line, so matching only the traceball
	@# line and printing it alone gives no usable info.
	@if [ -f $@.log ] && grep -qE "^E[0-9]+:|not modifiable|stack traceback:|Error executing|Press ENTER" $@.log; then \
	  echo ""; \
	  echo "ERROR: $@ rendered but nvim emitted error messages:"; \
	  echo ""; \
	  grep -B 4 -E "^E[0-9]+:|not modifiable|stack traceback:|Error executing|Press ENTER" $@.log \
	    | sed 's/^/  /'; \
	  echo ""; \
	  echo "Full message log: $@.log"; \
	  echo "Fix the tape (or the demo init / fixture) so the run"; \
	  echo "completes cleanly, then re-run 'make demos'."; \
	  exit 1; \
	fi
	@echo "wrote $@"

clean:
	@rm -rf $(DEPS_DIR)
	@echo "removed $(DEPS_DIR) (run 'make deps' to refetch)"
