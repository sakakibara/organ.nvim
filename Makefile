# organ.nvim development Makefile.
#
# `make test` is the canonical entry point — bootstraps test deps + builds
# the tree-sitter grammar + runs the suite.  Idempotent: re-running is fast.

NVIM      ?= nvim
TEST_DIR  := tests
DEPS_DIR  := $(TEST_DIR)/deps
GRAMMAR   := $(shell $(NVIM) --headless --noplugin -u NONE \
                 -c 'lua io.write(vim.fn.stdpath("data") .. "/organ/parser/org.so")' \
                 -c 'qa' 2>&1 | tr -d '\r')

.PHONY: help deps demo-deps grammar test test-only test-fold test-behavioral lint lint-md lint-doc clean \
        demos demos-force clean-demos parity parity-emacs parity-organ parity-update parity-check \
        parity-section parity-section-emacs parity-section-organ parity-section-check

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
	@echo "  make parity          regen organ + emacs snapshots and diff them"
	@echo "  make parity-emacs    regen tests/fixtures/parity/EMACS-EXPECTED.txt"
	@echo "  make parity-organ    regen tests/fixtures/parity/ORGAN-EXPECTED.txt"
	@echo "  make parity-update   regen both snapshots (commit the result)"
	@echo "  make parity-check    CI gate: regen both, fail if either drifts from committed fixture"
	@echo "  make clean           remove tests/deps/ (does NOT touch the built grammar)"

# Fetch test-time plugin dependencies (gitignored).  Idempotent.
deps:
	@bash scripts/test-deps.sh

demo-deps:
	@bash scripts/demo-deps.sh

# Fetch + build the tree-sitter grammars into <stdpath data>/organ/parser/.
# Nothing is vendored: grammar_install clones tree-sitter-organ and
# tree-sitter-organ-inline from GitHub and compiles them locally.
# Skips work when the .so is already up to date.
grammar:
	@$(NVIM) --headless --cmd "set rtp+=$(PWD)" \
	  -c 'lua require("organ.grammar_install").install()' \
	  -c 'qa' 2>/dev/null
	@test -f "$(GRAMMAR)" || (echo "grammar build failed: $(GRAMMAR) not found" && exit 1)

test: deps grammar test-only

# Walks tests/*_test.lua AND tests/behavioral/*_test.lua, running each
# in a clean nvim --headless invocation.  Reports the failing files at
# the end and exits non-zero if any failed.
test-only:
	@fails=0; failed=""; \
	for t in $(TEST_DIR)/*_test.lua $(TEST_DIR)/behavioral/*_test.lua; do \
	  [ -f "$$t" ] || continue; \
	  printf '\033[2m--- %s\033[0m\n' "$$t"; \
	  if ! timeout 30 $(NVIM) --headless -l "$$t" </dev/null; then \
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

lint-md:
	@command -v markdownlint-cli2 >/dev/null || { \
	  echo "markdownlint-cli2 not on PATH — install one of:"; \
	  echo "  npm install -g markdownlint-cli2"; \
	  echo "  brew install markdownlint-cli2"; \
	  exit 1; }
	@markdownlint-cli2 "**/*.md" "#node_modules" "#tests/deps"

lint-doc:
	@test -d $(DEPS_DIR)/vim-vimhelplint || (echo "vim-vimhelplint not in $(DEPS_DIR)/ -- run 'make deps'" && exit 1)
	@$(NVIM) -u NONE -i NONE --headless \
	  --cmd 'set rtp+=$(DEPS_DIR)/vim-vimhelplint' \
	  --cmd 'filetype plugin on' \
	  -c 'edit doc/organ.txt' \
	  -c 'verb VimhelpLintEcho' \
	  -c qa

# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Agenda parity: side-by-side snapshot of organ.nvim's render against
# real Emacs org-agenda output, both driven from tests/fixtures/parity/.
#
# Both snapshots are deterministic (Emacs script pins start-day +
# wall-clock; organ script disables virt_text tags and the help footer)
# so re-running on any host produces byte-identical text.  The agenda
# parity test (tests/agenda_parity_snapshot_test.lua) asserts the live
# organ render matches the committed ORGAN-EXPECTED.txt; the diff
# against EMACS-EXPECTED.txt documents the remaining divergences.
#
# Maintenance flow: `make parity-update` regenerates both snapshots,
# then commit the result so future test runs gate on the new state.
PARITY_DIR    := $(TEST_DIR)/fixtures/parity
PARITY_DATE   := 2026-05-04
PARITY_SPAN   := week
PARITY_EMACS  := $(PARITY_DIR)/EMACS-EXPECTED.txt
PARITY_ORGAN  := $(PARITY_DIR)/ORGAN-EXPECTED.txt

PARITY_SECTION_DIR    := $(PARITY_DIR)/section
PARITY_SECTION_SEED   := $(PARITY_SECTION_DIR)/seed
PARITY_SECTION_EMACS  := $(PARITY_SECTION_DIR)/EMACS-EXPECTED.txt
PARITY_SECTION_ORGAN  := $(PARITY_SECTION_DIR)/ORGAN-EXPECTED.txt

parity-emacs:
	@command -v emacs >/dev/null 2>&1 || { \
	  echo "emacs not on PATH; install GNU Emacs (apt: emacs-nox / brew: emacs) first" >&2; \
	  exit 1; \
	}
	@emacs --batch -Q -l scripts/emacs-agenda-snapshot.el \
	  --eval '(organ-snapshot "$(PWD)/$(PARITY_DIR)" "$(PARITY_DATE)" "$(PARITY_SPAN)")' \
	  2>/dev/null > $(PARITY_EMACS)
	@echo "wrote $(PARITY_EMACS) ($$(wc -l < $(PARITY_EMACS)) lines)"

parity-organ: grammar
	@$(NVIM) --headless -l scripts/organ-agenda-snapshot.lua \
	  $(PARITY_DIR) $(PARITY_DATE) $(PARITY_SPAN) \
	  2>/dev/null > $(PARITY_ORGAN)
	@echo "wrote $(PARITY_ORGAN) ($$(wc -l < $(PARITY_ORGAN)) lines)"

# Regenerate both snapshots and show the diff.  Exits 0 even if the two
# diverge -- divergences are documented, not blocking; the snapshot
# *test* (test-only) is what gates against drift.
parity: parity-emacs parity-organ
	@echo ""
	@echo "=== diff EMACS-EXPECTED.txt vs ORGAN-EXPECTED.txt ==="
	@diff -u $(PARITY_EMACS) $(PARITY_ORGAN) || true

# Convenience alias for the common maintenance flow: regen both
# snapshots in one shot, ready to commit.
parity-update: parity-emacs parity-organ
	@echo "snapshots regenerated; review with 'git diff $(PARITY_DIR)/' before committing"

# CI gate: regenerate both snapshots and fail if either has drifted
# from the committed fixture.  Catches both directions of drift:
#   * organ render changed without an explicit baseline update
#   * emacs upstream changed (new version produces different output)
# When this fires, run `make parity-update` locally, review the diff,
# then commit the new baseline.
parity-check: parity-emacs parity-organ
	@if ! git diff --quiet -- $(PARITY_EMACS) $(PARITY_ORGAN); then \
	  echo ""; \
	  echo "PARITY DRIFT detected against the committed fixtures:"; \
	  echo ""; \
	  git --no-pager diff -- $(PARITY_EMACS) $(PARITY_ORGAN); \
	  echo ""; \
	  echo "To accept the new baseline:"; \
	  echo "  make parity-update"; \
	  echo "  git add $(PARITY_DIR)/"; \
	  echo "  commit"; \
	  exit 1; \
	fi
	@echo "parity-check: no drift"

parity-section-emacs:
	@command -v emacs >/dev/null 2>&1 || { \
	  echo "emacs not on PATH; install GNU Emacs first" >&2; exit 1; }
	@TZ=UTC emacs --batch -Q -l scripts/emacs-section-snapshot.el \
	  --eval '(organ-section-snapshot "$(PWD)/$(PARITY_SECTION_SEED)")' \
	  2>/dev/null > $(PARITY_SECTION_EMACS)
	@echo "wrote $(PARITY_SECTION_EMACS) ($$(wc -l < $(PARITY_SECTION_EMACS)) lines)"

parity-section-organ: grammar
	@TZ=UTC $(NVIM) --headless -l scripts/organ-section-snapshot.lua \
	  $(PWD)/$(PARITY_SECTION_SEED) \
	  2>/dev/null > $(PARITY_SECTION_ORGAN)
	@echo "wrote $(PARITY_SECTION_ORGAN) ($$(wc -l < $(PARITY_SECTION_ORGAN)) lines)"

parity-section: parity-section-emacs parity-section-organ
	@diff -u $(PARITY_SECTION_EMACS) $(PARITY_SECTION_ORGAN) || true

parity-section-check: parity-section-emacs parity-section-organ
	@if ! git diff --quiet -- $(PARITY_SECTION_EMACS) $(PARITY_SECTION_ORGAN); then \
	  echo ""; \
	  echo "SECTION PARITY DRIFT against committed fixtures:"; \
	  git --no-pager diff -- $(PARITY_SECTION_EMACS) $(PARITY_SECTION_ORGAN); \
	  exit 1; \
	fi
	@echo "parity-section-check: no drift"
