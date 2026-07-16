# Contributing to organ.nvim

Thanks for taking the time.  This guide covers the quick path: how to
file a useful issue, how to send a PR, and how the test suite is
structured so you can verify your change locally before pushing.

## Filing an issue

Pick the matching template from
[`.github/ISSUE_TEMPLATE/`](./.github/ISSUE_TEMPLATE/):

- **Bug report** -- something doesn't work the way the docs say.
- **Feature request** -- a missing capability or an Emacs `org-*`
  setting that organ doesn't support yet.
- **Emacs / org-roam interop** -- a file that opens correctly in
  Emacs but breaks in organ (or vice versa).

Always include:

- Neovim version (`nvim --version | head -1`).
- organ.nvim version (`git rev-parse --short HEAD` if installed
  via lazy/plug from a checkout).
- Output of `:checkhealth organ`.
- The smallest org snippet that reproduces.  A 5-line file beats a
  description of a 500-line file.

For agenda / picker / completion bugs, run `:Org status` and include
the line count + last error.

## Submitting a PR

1. Fork, branch, code.
2. Add or update a test under `tests/` -- see **Test layout** below.
3. `make test` (canonical) or `make test-only` (fast iteration after
   the first `make test`).
4. `make lint` (stylua-checks the entire `lua/` tree).
5. Commit with a descriptive message -- see **Commit style**.
6. Open the PR; the CI workflow will run the same `make test`.

PRs that touch the public API or user-visible behavior need a doc
update too: `README.md` for top-of-funnel material, `doc/organ.txt`
for the help-tag reference.  CI doesn't enforce this -- reviewers do.

## Test layout

```text
tests/
  *_test.lua            unit + integration; one file per concern
  behavioral/           user-perceptible scenarios (capture, agenda dispatch, ...)
  fixtures/             read-only test data (org files, parity baselines)
  deps/                 gitignored test-time deps (fetched by scripts/test-deps.sh)
```

Every test bootstraps via `dofile("tests/_bootstrap.lua")`, which
verifies the tree-sitter grammar is built and the dep symlinks
resolve.  Tests print a `PASS  <label>` / `FAIL  <label>` line per
check and exit non-zero on any failure -- `make test-only` aggregates
the per-file results.

For features that touch user-visible buffer state, write a behavior
test (`tests/behavioral/`) rather than a unit test of the helper
function.  The behavior test catches the regression a real user would
hit; the unit test catches drift in a layer the user doesn't see.

## Commit style

Conventional-commits without the strict scope rules:

```text
fix(agenda): each day-header gets its own fold-open chevron
feat(spacing): empty-line policy for headline insert (auto-detect)
refactor(commands): hierarchical :Org subcommand groups
test(fold): comprehensive keymap coverage
```

Keep the subject under 70 chars.  Use the body for the WHY (a
specific incident, a constraint, a tradeoff) -- the diff already
shows the WHAT.

## Coding conventions

- ASCII punctuation only (no em-dash, smart quotes, ellipsis,
  Unicode arrows) in code, code comments, and commit messages.
  Prose (README, help, issues, PRs) is unconstrained.
- Comments explain WHY, not WHAT.  Don't narrate code; don't
  reference past commits or future TODOs in source.
- Don't add backwards-compatibility shims.  When an internal API
  changes, update every caller.  No `if old_api then ... else ... end`.
- For UI-touching changes, exercise the feature in a real Neovim
  session before declaring done.  The test suite verifies code
  correctness, not feature correctness.
- `make lint` runs stylua and luacheck (`luarocks install luacheck`);
  both must be clean before a PR.

### Error handling

organ follows the standard Lua model, split by whether a failure is part
of normal control flow:

- **Expected / recoverable** (not found, no match, a user-supplied path
  that does not exist): return `nil` (or `nil, msg` when the reason is not
  self-evident).  The caller handles it inline.
- **Exceptional / invariant** (a hardcoded query fails to prepare, a
  handle is missing where it must exist, an impossible node kind): call
  `error(msg, 2)` with a `module.context:` prefix, or use
  `organ.errors.check(cond, ctx, msg)`.

Catch only at the outermost user-facing boundary -- command handlers,
keymap callbacks, autocmds, and scheduled callbacks -- via
`organ.errors.guard(ctx, fn)` (or `errors.schedule` / `errors.autocmd`,
which wrap the callback for you).  `pcall` cannot catch a throw on a
later `vim.schedule` stack, so scheduled callbacks must be guarded at the
point they are scheduled.  Do **not** add `pcall` mid-chain in internal
code -- it only swallows context and hides bugs.

## Where to look

- `lua/organ/`       -- module per feature
- `plugin/organ.lua` -- `:Org` dispatcher + tree
- `queries/`         -- tree-sitter queries (highlights + injections)
- `doc/organ.txt`    -- vim help (the reference)
- `assets/tapes/`    -- VHS tape scripts (source of truth for demos; commit these)
- `assets/demos/`    -- rendered GIFs (CI-only; gitignored + guard-enforced, never commit)
- `assets/`          -- icons, demo assets, macOS notifier helper

### Sister repositories

Runtime / grammar code lives in separate repos.  Bugs and PRs
against any of them go to the upstream repo, not here:

- [tablature.nvim](https://github.com/sakakibara/tablature.nvim) — table editing primitives (runtime dep)
- [narrow.nvim](https://github.com/sakakibara/narrow.nvim) — subtree narrowing (runtime dep)
- [tree-sitter-organ](https://github.com/sakakibara/tree-sitter-organ) — block-level tree-sitter grammar (cloned by `grammar_install.lua`)
- [tree-sitter-organ-inline](https://github.com/sakakibara/tree-sitter-organ-inline) — inline tree-sitter grammar (emphasis, links, timestamps, ...)
