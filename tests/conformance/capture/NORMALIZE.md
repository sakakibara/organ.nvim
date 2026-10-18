# Capture gate: case format, operations, settings and normalization

The gate runs one operation per case (capture with a template, refile,
archive, attach, ID creation, an org-roam query, publish) on a small fixture
tree, through Emacs (`emacs.el`) and through organ (`organ.lua`), and diffs
the two reports. Run it with

    CONFORMANCE_ORG_ROAM_PATH=<dirs> TZ=UTC LC_ALL=C nvim --headless -l tests/conformance/capture/gate.lua

`CONFORMANCE_ORG_ROAM_PATH` is a colon-separated list of load-path entries
that provide org-roam and its dependencies (compat, dash, emacsql,
magit-section, org-roam). When it is unset, `conformance-run` signals an
error naming the variable and the gate fails. A local run against elpaca
builds:

    B=~/.config/emacs/elpaca/builds
    CONFORMANCE_ORG_ROAM_PATH=$B/compat:$B/dash:$B/emacsql:$B/magit-section:$B/org-roam

Oracle versions: Emacs 31.1, org 9.8.7 (built in), org-roam
v2.2.2-67-g9fd7c87 (the `org-roam-version` of the builds above).

## Case format

A case is one file in `cases/`. It holds only the fixture tree; the
operation is the one registered under the case's basename in both
`emacs.el` (`cf-defop`) and `organ.lua` (`OPS`). Header lines before the
first file:

| Key | Meaning |
|-----|---------|
| `#+CONFORMANCE-FILE: PATH` | Starts a fixture file; the lines up to the next `FILE` line are its content, each ending in a newline. `PATH` may contain directories. |
| `#+CONFORMANCE-DIR: PATH` | An empty directory to create. |
| `#+CONFORMANCE-OPTIONS: NAMES` | The option runs the case takes part in. |

Other lines before the first file (`# ...`) are comments. Each case runs in a
fresh work directory `<root>/<case>/work`, where `<root>` is a new temporary
directory and is also `HOME` on both sides (see Paths).

## Report

Each side prints, in order: the operation's own lines (markers such as
`-- id target`, query results, `ERROR: <message>` when the operation signals),
then a dump of the files the operation leaves: per file a `=== PATH` line,
the file's bytes, and `<<EOF>>`. Files are listed by path in byte order.
Cases that report a query (refile targets, roam nodes, publish listings,
attach directories) print only that.

The operation on each side, per case (organ calls are in `organ.lua`):

| Case | Emacs | organ |
|------|-------|-------|
| `capture-*` | `org-capture` with the template, text typed at point, `org-capture-finalize` | `capture.start` with the equivalent template, text typed where the capture buffer puts the cursor, `capture.finalise`; a failed finalise closes the capture buffer, as Emacs aborts |
| `capture-types`, `capture-file-regexp` | `plain` / `item` / `checkitem` / `table-line` templates | `type = "<same>"` in the template |
| `capture-empty-lines`, `capture-template-properties`, `capture-datetree-*` | `:empty-lines`, `:immediate-finish`, `:clock-in`, `:jump-to-captured`, `:tree-type`, `:time-prompt` | `empty_lines`, `immediate_finish`, `clock_in`, `jump_to_captured`, `tree_type`, `time_prompt` (the ledger's names; organ ignores them today) |
| `capture-targets`, `capture-escapes-clock-file-sexp` | `org-clock-in` / `org-clock-out` | `clock.start` / `clock.stop` |
| `refile-default-targets`, `refile-targets` | `org-refile-get-targets`, each printed as `FILE:OUTLINE/TITLE` | the refile picker's candidates in the same form |
| `refile-*` (moves) | `org-refile` / `org-refile-copy`, answering the target prompt | `refile.refile` with the picker choosing the same target |
| `refile-targets` (third view) | `:tag` / `:todo` / `:regexp` rules | `tag` / `todo` / `regex` rule keys (ignored today) |
| `archive-*` | `org-archive-subtree`, `org-archive-to-archive-sibling`, `org-toggle-archive-tag`, `org-archive-subtree '(4)` | `archive_subtree`, `archive_to_sibling`, `set_archive_tag`; `archive-all-done` has no organ command and leaves the files |
| `archive-mark-done`, `archive-reversed-order` | `org-archive-mark-done`, `org-archive-reversed-order` | `archive.mark_done`, `archive.reversed_order` (the ledger's names) |
| `attach-*` | `org-attach-attach` (copy), `org-attach-dir`, `org-attach-expand` | `attach.attach`, `attach.dir`, `link.open("attachment:...")` |
| `id-*` | `org-id-get-create`, `org-id-new`, `org-id-find`, `org-id-locations-save`, `org-link-open-from-string` | `id.get_or_create`, `id.generate`, `query.get_by_id`, `id.export_locations`, `link.open` |
| `roam-nodes` | org-roam's `nodes`, `aliases`, `refs` and `id` rows of `links` | organ's headlines with an ID, `aliases`, (no refs table), `id` rows of `links` |
| `roam-create-node`, `roam-daily-existing` | `org-roam-capture-` (immediate), `org-roam-dailies-capture-today`, `org-roam-node-slug` | `roam.create_node`, `roam.dailies.today` then text typed at the end of the cursor's line, `slug.slugify` |
| `roam-links` | `org-link-open-from-string "[[roam:...]]"` | `link.open("roam:...")` |
| `publish-*` | `org-publish`, `org-publish-get-base-files` | `publish.publish` (a recording publishing function for `publish-exclude`) |

Where a template prompts, both sides get the same answers in the same order.
Where an ID is generated, both sides print its shape (`h` for a lower-case
hex digit, `H` for upper case) and the version digit; for the `ts` method the
part after the seconds is printed with `d` for each digit.

## Paths

Paths under the work directory print as `$WORK`; the same paths in `~/`
form print as `~$WORK`. Both sides set `HOME` to the temporary root so the
work directory lies under it, as it did in the audit: whether a path is
abbreviated is part of CF-24 and CF-45, and a fixed `HOME` makes that
independent of where the checkout lives. Emacs resets
`abbreviated-home-dir`; organ sets `vim.env.HOME`, which `fnamemodify(":~")`
reads (`stdpath()` is unaffected). This is output shaping on each side, not
a normalization.

## Normalization (`normalize.lua`)

1. `ERROR: <message>` becomes `ERROR`. The gate compares whether an
   operation signalled and what it left in the files; the wording of an Emacs
   error and an organ notification is not part of the org format and never
   matches. Errors are attributable because multi-step operations print a
   marker line before each step.
2. A UUID that does not occur in the case file is replaced by
   `<ID of FILE::HEADING>`, naming the element whose `:ID:` line holds it in
   the dump (`FILE::` for a file-level drawer); a UUID no `:ID:` line holds
   becomes `<UUID-N>` by first appearance. Its attachment-directory form
   (`XX/REST`) becomes the same label plus ` as dir`. New IDs are random on
   both sides; the label keeps which element received an ID, and two
   different IDs never share a label. IDs given in the fixture compare
   literally.
3. The trailing `=== PATH` sections are re-sorted by path after rule 2,
   because an attachment path that contains a random ID sorted at a random
   place. Text whose tail is not a clean run of sections is left as it is.

Nothing else is normalized: blank lines, tag alignment, drawer indentation,
timestamps (the clock is pinned) and user identifiers compare literally.

## Settings

Emacs (`emacs.el`), for every case:

| Setting | Reason |
|---------|--------|
| `conformance-clock-pin` (2026-05-04 09:30 UTC) | Contract. The publish case drops the pin while publishing: org-publish compares file modification times with the real clock (CF-85). |
| `org-todo-keywords` = organ's default sequence (`TODO NEXT WAITING HOLD PROJ \| DONE CANCELLED`) | Both sides must agree on what a keyword is; the same value as the other gates. |
| `org-directory` = the work directory | Relative capture targets resolve against it, as organ's paths are under the work directory. |
| `org-id-locations-file` outside the work directory (inside it for `id-links-locations`) | Keeps the file out of the dump unless the case compares it. |
| `org-id-uuid-program` = `"true"` | `uuidgen` prints upper case on macOS and lower case on Linux; with no usable program org uses its own v4 generator, so the shape does not depend on the platform (CF-60). |
| `user-full-name` "Test User", `user-login-name` "tester" | The identity `%n` reads (CF-22); organ's `os_get_passwd` is stubbed to the same login name. |
| `system-time-locale` "C" | English day and month names, as organ prints. |
| `make-backup-files`, `auto-save-default`, `create-lockfiles` off; `org-bookmark-names-plist` nil | No extra files in the work directory. |
| org-roam loaded only for the `roam-*` cases, which run last | Loading org-roam rebinds the `id` link type to `org-roam-id-open`, which ignores `::search` options (CF-64 needs org's own). The audit loaded it only for its roam cases. |
| `org-roam-directory` = the work directory, the database outside it, `org-roam-db-update-on-save` off | As the audit's `em-roam.el`. |
| `org-publish-timestamp-directory` outside the work directory, `org-export-with-toc` and `org-html-validation-link` off | As the audit; HTML bodies belong to the html gate, only hrefs are printed. |

Prompts are answered from a queue on both sides; Emacs's minibuffer readers
and `org-read-date`, organ's `vim.ui.input` / `vim.ui.select`.

organ (`organ.lua`): `plugin/organ.lua` is sourced and filetype plugins are
on, as at a normal start. For every case: `setup{org_dir, notify = true,
scan_on_startup = false, debounce_ms = 0, watcher = {enabled = false},
agenda_files, find.backend}` isolates the run (the backend records the
refile candidates and picks the case's target). Per case: `org_dir` and
`agenda_files` point at the work directory and `db_path` at a fresh database.
The clock's persisted state is kept in memory instead of
`stdpath("data")`; the `+`/`*` registers read as empty (batch Emacs has no
clipboard); `vim.notify` records only ERROR-level notifications;
`notify.repeat_suppress_seconds = 0`, because the pinned clock would
otherwise suppress a repeated notification across cases. Every other value
is organ's default. Buffers, the database handle and the config are reset
after each case.

## Option runs (`options.lua`)

| Run | Cases | organ setting | Ruling |
|-----|-------|---------------|--------|
| `refile-current-file` | `refile-default-targets` | `refile.targets = {{files = "current", max_level = 1}}` | CF-35 KEEP+OPT: Emacs's default (level-1 headings of the current file). |
| `uuid-v4` | `id-create` | `links.id_method = "uuidv4"` | CF-60 KEEP+OPT. |
| `attach-no-link` | `attach-id-layouts` | `attach.auto_insert_link = false` | CF-70 KEEP+OPT. |
| `flush-left-drawers` | `archive-default`, `attach-id-layouts`, `capture-escapes-clock-file-sexp`, `capture-targets`, `id-create`, `refile-log` | `todo.planning_indent = 0` | CF-59 KEEP+OPT. The ruling names `indent.adapt_indentation = nil`; in organ that key re-indents existing body lines (formatter, moved subtrees) and is already off by default, while new drawers take their indentation from `todo.planning_indent`, whose `0` writes them flush left. |

Emacs runs with its defaults in every option run. No option run holds a
row of the ID it serves: the run shows the option reaches Emacs's form.
`refile-current-file` shows no difference at all, so it has no signatures
file.

## Coverage outside the diff (index.tsv)

- `unit`: CF-16 and CF-17 are capture-buffer keymaps (interactive; the FIX
  parts are the Insert-mode `ZZ`/`ZQ` maps and the unmapped
  `refile_finalise` key). CF-19 and CF-82 are documentation errors: the
  `%t`/`%T`/`%u`/`%U` output already matches (`capture-escapes-basic`), and
  the documented publish keys are an organ-only probe with no Emacs side.
- `option:<run>` `pass`: CF-35, CF-59, CF-60, CF-70; the default run holds
  their KEEP rows and the option run holds none.

## Signature notes

A row's class must be allowed by every ID it names, so a hunk that also
carries a KEEP difference (CF-18, CF-57, CF-59, CF-70) is keyed TRANSITIONAL
with its FIX IDs, and the KEEP contribution is named in a `#` comment line
above the row. Such rows change text, not existence, once their FIX parts
land: the KEEP part remains.

- `capture-escapes-clock-file-sexp`: Emacs's `%K` expands to
  `[[file:~$WORK/src.org:::END:\n** Other]]`, a link whose search string is
  the text after the clock drawer, not the clocked heading. The row is keyed
  to CF-26 (organ leaves `%K` verbatim); when CF-26 is fixed the target for
  `%K` needs a ruling (Emacs's own output is defective, R5).
- `capture-datetree-*`: the template-key rows name CF-15 (`:tree-type`,
  `:time-prompt` not recognised) with CF-30 where the tree shape is the
  subject.
- `attach-id-layouts`: the fixture's UUID starts with digits so that a
  generated ID cannot share its attachment directory on a case-insensitive
  file system.

## Corpus provenance

Cases come from the audit harness
(`2026-10-18-emacs-divergence/capture-files/cases/<case>/in`); the operations
port each case's `em.el` / `og.lua` with both sides doing the same operation.

| Case | Audit case | Changes |
|------|-----------|---------|
| `capture-entry-file`, `capture-file-headline`, `capture-entry-without-star`, `capture-relevel`, `capture-prepend`, `capture-types`, `capture-file-regexp`, `capture-file-olp`, `capture-template-whitespace`, `capture-template-properties` | `cap-entry-file`, `cap-headline`, `cap-nostar`, `cap-relevel`, `cap-prepend`, `cap-types`, `cap-regexp`, `cap-olp`, `cap-ws`, `cap-props` | organ gets the Emacs template type and property names; olp captures print markers. |
| `capture-empty-lines`, `capture-blank-separated-file` | `cap-emptylines` | Split so CF-10 and CF-11 hunks are separate. |
| `capture-targets`, `capture-missing-directory` | `cap-targets` | Split; organ clocks in as Emacs does. |
| `capture-escapes-basic`, `capture-escapes-annotation`, `capture-escapes-clock-file-sexp`, `capture-escapes-prompts` | `cap-esc-*` | Templates reordered or split into one capture per escape group; the same prompt answers on both sides; the hand-built `%a` context probe dropped (organ-only); `links.org` added. |
| `capture-datetree`, `capture-datetree-existing`, `capture-datetree-week-month`, `capture-datetree-tree-types` | `cap-datetree`, `cap-datetree-edge`, `cap-datetree-week`, `cap-datetree-more` | organ uses `tree_type` per template instead of the global format list. |
| `refile-default-targets`, `refile-targets` | `ref-targets` | Split; targets printed as `FILE:OUTLINE/TITLE` on both sides. |
| `refile-move`, `refile-copy`, `refile-same-file`, `refile-top-level`, `refile-create-parent`, `refile-reverse-order`, `refile-log` | `ref-*` | none |
| `archive-default`, `archive-in-file`, `archive-mark-done`, `archive-sibling`, `archive-tag-toggle`, `archive-datetree` | `arc-*` | none |
| `archive-heading-location`, `archive-level-2-heading`, `archive-missing-directory` | `arc-heading` | One archive per case. |
| `archive-keyword-after-line-50`, `archive-keyword-first-wins`, `archive-inherited-property` | `arc-loc` | One file per case. |
| `archive-all-done`, `archive-reversed-order`, `archive-location-without-colons` | `arc-misc` | One behaviour per case. |
| `attach-id-layouts`, `attach-existing-dirs` | `attach`, `attach-lookup` | UUID fixture ID changed (see notes). |
| `id-create`, `id-duplicate`, `id-links-locations` | `id-create`, `id-dup`, `id-links` | Marker lines between steps. |
| `roam-nodes`, `roam-create-node`, `roam-daily-existing`, `roam-links` | `roam-*` | `roam-links` opens the links on both sides instead of Emacs's `org-roam-link-replace-all`. |
| `publish-recursive-sitemap`, `publish-exclude`, `publish-components` | `publish`, `publish-exclude`, `publish-opts` | `publish-components` publishes `site` only on both sides. |

Not promoted: `cap-keymaps` (interactive, see Coverage) and `emacs-defaults`
(an Emacs-only listing of variable defaults).
