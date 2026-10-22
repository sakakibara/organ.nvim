# Babel-links gate: case format, settings and normalization

The gate runs operations on org buffers through Emacs (`emacs.el`) and
through organ (`organ.lua`): babel execution and tangling, link following,
storing and inserting, footnote commands, and citation parsing, following,
insertion and bibliography lookup. Each side prints the resulting buffer,
the files the operation wrote, the place point ends up, or the parsed data,
in one shared text shape, and the runner diffs the two texts per case. Run
it with
`TZ=UTC LC_ALL=C nvim --headless -l tests/conformance/babel-links/gate.lua`.

## Case format

A case is one file in `cases/`. Leading `#+CONFORMANCE-KEY: value` lines
configure the run. The lines after them, up to the first
`#+CONFORMANCE-FILE: NAME` line, are `case.org`; each `#+CONFORMANCE-FILE:`
line starts another file of the case, written under NAME (subdirectories
allowed). Every file is written with a final newline.

| Key | Meaning |
|-----|---------|
| `OP` | One operation (repeatable, run in order on the same buffer); see below. |
| `EMACS` | One `(VARIABLE FORM)` binding around the Emacs run (repeatable). |
| `EMACS-EVAL` | One form evaluated in the visited buffer before the operations. |
| `ORGAN` | One Lua statement run in the visited buffer before the operations; `B` is the buffer, `DIR` the case directory, `M(mod)` requires `organ.<mod>`, `set(path, value)` sets a buffer-local config value. |
| `DIR` | A directory created in the case directory. |
| `SYMLINK` | `LINK TARGET`: a symbolic link created in the case directory. |
| `PROMPTS` | Print the confirmation prompts the operation showed. |
| `OPTIONS` | Option runs this case takes part in. |

In `case.org`, `<CURSOR>` marks point (default: the buffer start) and
`<MARK>` the other end of an active region; both markers are removed and
the buffer starts unmodified.

Operations and the calls on each side:

| Op | Emacs | organ |
|----|-------|-------|
| `execute` | `org-babel-execute-maybe` | `babel.execute(B)` |
| `execute-buffer` | `org-babel-execute-buffer` | `babel.execute_buffer(B)` |
| `tangle` | `org-babel-tangle` | `babel.tangle(B)` |
| `follow` | `org-open-at-point` | `link.follow()` |
| `store [FILE]` | `org-store-link` (in FILE when given), then `org-insert-link` on a new last line of case.org | `link.store_link()` (in FILE when given), then `link.insert_link()` on a new last line |
| `insert-link URL [DESC]` | `org-insert-link`, answering URL and DESC at its prompts | `link.insert_link()` with URL/DESC pushed as the newest stored link |
| `fn-action` | `org-footnote-action` | `footnote.jump(B)` |
| `fn-new` | `org-footnote-new` | `footnote.insert()` |
| `fn-sort` / `fn-normalize` / `fn-renumber` | `org-footnote-sort` / `org-footnote-normalize` / `org-footnote-renumber-fn:N` | `footnote.sort()` / `footnote.normalize_inline(B)` / `footnote.renumber()` |
| `fn-delete` | `org-footnote-delete` | none; organ has no footnote delete and reports an error |
| `cite-parse` | every `citation` element of `org-element-parse-buffer` | `cite.scan` over the buffer text |
| `cite-insert KEY` | `org-cite-insert`, choosing KEY's entry | `:Org cite find`, choosing KEY's row |
| `cite-bibliography` | nothing (Emacs has no buffer command; the keyword stays) | `:Org cite bibliography` |
| `bib-files` | `org-cite-list-bibliography-files` and `org-cite-basic--all-keys` | `cite.find_bibliographies` and the keys of `cite.completion_items` |

## Output shape

Sections, each present only when it applies, in this order:

- `! error OP`: the operation signalled an error (Emacs) or organ reported
  that it did nothing (`false` from execute, execute-buffer or footnote
  jump, or a Lua error).
- Operation data: `=== stored LINK` / `=== description DESC` (store);
  `=== citations` then one `L<line> style= pre= suf= refs=(key pre suf)...`
  line per citation; `=== bibliography` and `=== keys` (bib-files).
- `=== point FILE LINE:COL` after `follow`, `fn-action` and `fn-new`
  (1-based line, 0-based column); after `follow` also `=== line TEXT`, the
  line point is on.
- `=== buffer` and case.org's text, except for `follow`, `cite-parse` and
  `bib-files`, which leave the buffer as it was.
- `=== open URL` per URL handed to the browser (`browse-url` and
  `vim.ui.open` are stubbed to record it).
- `=== prompts` and `? PROMPT` lines, when the case asks for them.
- `=== files`: every file or symlink under the case's temporary root that
  the operation created, changed or deleted, as `--- PATH (MODE)` plus its
  text, or `--- PATH -> TARGET`. PATH is relative to the root; case.org
  lives in `w/`, so a file written outside the case directory shows up
  without the `w/` prefix.

## Settings

Both sides:

- Each case runs in a fresh temporary directory `ROOT`, with its files in
  `ROOT/w`, so tangling, `:file` output and every other write stay inside a
  directory the gate deletes. Emacs visits `ROOT/w/case.org`, whose
  directory is its default directory as always; organ's working directory
  is `ROOT` for the case (restored after), so a write or `:dir` resolved
  against Neovim's working directory instead of the file's lands in a
  visible, different place (BL-27).
- Prompts are answered yes: Emacs `yes-or-no-p` / `y-or-n-p`, organ
  `vim.fn.confirm`. Babel confirmation stays at each side's default (on),
  so every executed block is confirmed on both sides; prompt texts are
  printed only where a case asks (`eval-query.org`, `confirm-prompt.org`),
  because they are the subject of BL-24 / BL-44 and would otherwise put the
  same prompt-wording hunk into every execution case. `eval-query.org`
  turns confirmation off on both sides (`org-confirm-babel-evaluate nil`,
  `babel.confirm_evaluate = false`), as the BL-24 repro requires.
- Link insertion picks the newest stored link (organ `vim.ui.select` takes
  the first item; Emacs `completing-read` / `read-string` return the
  initial input or default, or the answer the case names).
- The clock is pinned through `../_clock.el` / `../_clock.lua`.

Emacs only:

- `ob-shell`, `ob-python`, `ob-emacs-lisp`, `oc-basic` are loaded: organ
  ships runners for sh and python and a citation follower, so the Emacs
  languages and processor organ is compared with must be active.
- `org-babel-python-command` is `"python3"`, the interpreter organ runs.
- `org-id-track-globally` is nil and `org-id-locations-file` a temporary
  file, so creating an ID never writes into the user's Emacs directory.
- `make-backup-files`, `auto-save-default` and `create-lockfiles` are nil,
  so no `~`, `#...#` or `.#` file shows up among the written files.
- `enable-local-variables` is nil: case files carry no local variables.

organ only: `notify = false`, `scan_on_startup = false`, `debounce_ms = 0`
and the watcher off, so no background work runs during a case; `vim.notify`
is silenced while a case runs.

Per-case settings (each named in the case header):

- `default-header-args.org`: `org-babel-default-header-args:sh` and
  `org-babel-default-header-args` carry the defaults BL-48 is about.
- `fn-new-local.org`, `fn-new-anonymous.org`, `fn-new-define-inline.org`:
  `org-footnote-section nil`, `org-footnote-auto-label 'anonymous`,
  `org-footnote-define-inline t`, the settings BL-203 / BL-211 compare.
- `store-id-create-*.org`: `org-id-link-to-org-use-id t` against
  `links.id_link_policy = "create"`, the BL-127 / BL-132 repros.
- `abbrev-function.org`: `upcase` marked `org-link-abbrev-safe`, as the
  BL-117 repro does.
- `follow-modified-buffer-*.org`: both sides edit line 2 first; organ also
  indexes the directory first for the `id:` case (BL-111).

## Option runs

`id-link-nil`: organ `links.id_link_policy = false` (Emacs keeps its
default `org-id-link-to-org-use-id nil`). Only `store-existing-id.org`
takes part; it shows that the option reaches Emacs's choice of a
`*Headline` link over the existing `:ID:` (BL-123).

## Normalization

In the producers (`emacs.el`, `organ.lua`):

1. The case directory (`ROOT/w`, also in its symlink-resolved form) is
   written `<DIR>`, the root `<ROOT>`. They are fresh temporary paths that
   differ per run and per side; the relation of a path to them is what
   carries meaning, and it is kept.
2. Citation affixes are trimmed and a whitespace-only affix is printed as
   nil. org-element keeps the blank before `@key` as the reference's
   prefix (`; @doe` has prefix " "); the separator blank is not affix text.
3. Citation styles print through org-cite-basic's short-name table
   (`t` -> `text`, `b` -> `bare`, ...), and the default style as `nil`.
   oc-basic defines those names as the same style; organ resolves them
   while parsing, Emacs when exporting.

In `normalize.lua` (both sides):

1. UUIDs (8-4-4-4-12 hex) are numbered `<ID1>`, `<ID2>`, ... in order of
   first appearance, case-insensitively. A created `:ID:` is random on
   both sides (Emacs `uuidgen`, organ UUID v7); numbering keeps every
   place one ID recurs (drawer, stored link, inserted link) tied together.
   User IDs such as `abc-123` are not UUIDs and compare literally.
2. U+200B (zero-width space) is written `<U+200B>`, so the character
   Emacs appends to a description ending in `]` (BL-127) is visible in the
   signatures.

Nothing else is normalized: blank lines, result markup, file modes, error
markers and every link, label, name and ID compare literally.

## Case changes from the audit corpus

- `noweb-prefix-call-ref.org` and `noweb-missing.org` tangle the noweb
  block instead of executing it. Executed, the literal `<<grp>>` /
  `<<missing>>` organ leaves in the body is a shell syntax error whose text
  differs between shells (bash, dash); the tangled body shows the same
  expansion without depending on the shell.
- `coderef-label.org` uses a python body whose label sits at the end of a
  line inside a string, for the same reason: a label left in a sh body is
  a shell-specific syntax error.
- `tangle-link-subdir.org` holds only the `:comments link` block from a
  subdirectory; the unknown-language block of the same audit file is its
  own case (`tangle-unknown-language.org`, see TRIAGE.md).
- `file-output-dir.org` keeps the relative `:output-dir`; the audit's
  absolute `/tmp/bl-od` variant is left out, since it writes outside the
  case directory.
