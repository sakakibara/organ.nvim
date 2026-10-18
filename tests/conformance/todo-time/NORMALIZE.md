# todo-time gate: case format, settings and normalization

The gate runs each case's operations (TODO state changes, clocking,
dynamic block updates, scheduling, timestamp shifts, column view, date
prompt, effort and timer input) through Emacs (`emacs.el`) and through
organ (`organ.lua`) and diffs the two texts per case. Run it with
`TZ=UTC LC_ALL=C nvim --headless -l tests/conformance/todo-time/gate.lua`.

## Case format

A case is one file in `cases/`. Leading `#+CONFORMANCE-KEY: VALUE` lines
configure the run; the rest is written to a fresh directory as `t.org`,
and each `#+CONFORMANCE-FILE: NAME` line starts a further file of the case.
`<CURSOR>` marks where point starts; it is removed before the files are
written, so a freshly visited buffer is unmodified on both sides.

| Key | Meaning |
|-----|---------|
| `OP` | One operation (repeatable, run in order); see below. |
| `INPUT` | One answer (repeatable, consumed in order) for whatever the operations ask: log notes, minibuffer reads, completing reads, `read-number`; organ's `vim.ui.input` / `vim.ui.select`. An empty value is an empty answer. |
| `KEYS` | Characters answered to `read-char-exclusive` (Emacs) and `vim.fn.getcharstr` (organ). |
| `NOW` | `YYYY-MM-DD HH:MM` (UTC) both clocks are pinned to; default `2026-05-04 09:30`. |
| `DEFAULT` | The default time `org-read-date` receives for `read-date` (as when rescheduling an entry). organ's parser has no default (TD-93). |
| `EMACS` | One `(VARIABLE FORM)` default value for the Emacs side, restored after the case. |
| `ORGAN` | One Lua statement mutating `cfg` (organ's config) for the organ side. |
| `PROFILE` | `defaults`: organ runs on its own defaults instead of the baseline below. |
| `OPTIONS` | Space-separated option runs this case takes part in. |

Operations:

| Op | Emacs | organ |
|----|-------|-------|
| `cycle` | `org-todo` with `this-command` `org-todo` and `last-command` `next-line` (a fresh press) | `todo.cycle` |
| `cycle-repeat` | the same with `last-command` `org-todo` (a repeated press) | `todo.cycle` |
| `right` / `left` | `(org-todo 'right)` / `(org-todo 'left)` (S-right / S-left) | `todo.cycle` / `todo.cycle_back` (organ's S-right / S-left) |
| `todo STATE` | `(org-todo "STATE")`, `none` -> `'none` | `:Org todo STATE` |
| `priority X` | `(org-priority ?X)` | `inline_edit.set_priority` |
| `note` | `org-add-note` | `:Org add_note` |
| `goto TEXT` / `at L:C` | point to the first occurrence of TEXT / line L, byte column C | the same |
| `adv SECS` | advance the pinned clock | the same |
| `clock-in` / `clock-out` / `clock-cancel` | `org-clock-in` / `org-clock-out` / `org-clock-cancel` | `:Org clock in` / `out` / `cancel` |
| `clocking?` / `modified?` | print `clocking=` / `modified=` | the same |
| `schedule DATE` / `deadline DATE` | `(org-schedule nil DATE)` / `(org-deadline nil DATE)` | `schedule.set_schedule{date}` / `set_deadline{date}` (the agenda's entry point) |
| `schedule-prompt` | `call-interactively org-schedule`, answered from `INPUT` | `:Org schedule`, then `<CR>` in the picker |
| `up [N]` / `down [N]` | `(org-timestamp-up N)` / `down` | `inline_edit.dispatch`; with N, `:normal N<C-a>` / `N<C-x>` through the buffer keymap |
| `eval-range` | `(org-evaluate-time-range t)` | `:Org! evaluate_time_range` |
| `update-dblock` / `update-all-dblocks` | `org-update-dblock` / `org-update-all-dblocks` | `:Org update_dblock` / `update_all_dblocks` |
| `clock-report` | `org-clock-report` | `:Org clock report` |
| `set-effort` | `call-interactively org-set-effort` | `property.set_effort_interactive` (`:Org set_effort`) |
| `columns` / `columns-global` | `org-columns` at point / for the whole buffer, then `org-columns-quit` | `:Org columns` at point / on line 1 |
| `duration S` | `org-duration-to-minutes` | `effort.parse` |
| `read-date INPUT` | `(org-read-date nil t INPUT nil DEFAULT)` | `capture.date_answer.parse(INPUT, now)` |
| `timer` | `org-timer-set-timer`, answered from `INPUT` | `timer.start(INPUT)` |

## Output

Both sides print the final text of `t.org`, then, when anything was
logged, a `--- log` line followed by the log lines in order:

- `! refused` for an operation that was refused: on Emacs an error
  signalled by the operation or its log note, or org-todo's "state change
  ... blocked" message (org-todo only signals that refusal as a user-error
  when called interactively, which batch never is); on organ a returned
  error or a notification at WARN or ERROR level.
- `clocking=t|nil`, `modified=t|nil`.
- Column view: `L<line>: KEY="value" ...` per row, the value each cell
  shows (Emacs: the overlay's `org-columns-value-modified`, organ: the row
  value after `apply_summaries`), keys upper-cased.
- `? choices: ...` for the candidates a completing read or `vim.ui.select`
  offered.
- `read-date INPUT -> YYYY-MM-DD Day HH:MM T|-[ end=HH:MM]` (`T` when a
  time was given) or `unrecognised` (organ only).
- `duration "S" -> MINUTES|invalid`, `timer=SECONDS|none`.

A pending Emacs log note is completed after every operation, as the
command loop's `post-command-hook` does, also after an operation that
signalled.

## Normalization

1. `normalize.lua` removes trailing blanks from headline lines on both
   sides. They carry no meaning in org (org-element trims the title), and
   `org-columns` leaves padding spaces at the end of short headlines.
2. Each side replaces its case directory with `<DIR>/` in its own output.
   The directory is a per-run temporary path; it reaches the text through
   `:link t` file links in dynamic blocks.
3. Refusals compare as presence (`! refused`), not message text. Message
   wording is not org syntax; R7's contract is that the buffer is left as
   it was and the user gets a message.

Nothing else is normalized: blank lines, alignment, drawer placement,
indentation and timestamps compare literally.

## Settings

Emacs, for every case: `system-time-locale` `"C"` (English day and month
names, as organ prints); `org-read-date-popup-calendar` nil (batch has no
calendar window; the typed answer is what is compared);
`org-agenda-files` = the case's files (organ's `agenda_files` is set to the
same list) for clocktable `:scope agenda`; `yes-or-no-p` / `y-or-n-p`
answer yes; the prompt functions above answer from `INPUT` / `KEYS`.
Org's internal note state (`org-log-setup`, the note hook) and the
running clock and countdown are reset between cases.

organ baseline, for every case without `PROFILE: defaults`:
`todo.sequence = {"TODO", "|", "DONE"}`, `todo.log_done = false`,
`todo.planning_indent = 0`. These are the Emacs-default equivalents the
audit ran organ with, so each case isolates one difference; organ's own
defaults (TD-32, TD-33, TD-34, TD-35, TD-68, TD-75) are compared in the
`defaults-*` cases. Isolation only, with no effect on output:
`setup{org_dir = <temp>, scan_on_startup = false, debounce_ms = 0,
watcher = {enabled = false}}`; the running clock is kept in memory
instead of `<stdpath data>/organ/clock.json`, which belongs to the user;
`notify.repeat_suppress_seconds = 0`, because under the pinned clock an
identical refusal in a later case would otherwise be suppressed;
`filetype plugin indent on`, so buffers get ftplugin/org.lua's keymaps
(counted `<C-a>` goes through them). The case files are indexed before
the operations (clocktables and the clock report read the index) and
forgotten afterwards.

Per-case settings, each from the ledger repro of the entry the case
covers:

| Case | Emacs | organ |
|------|-------|-------|
| `log-done-note.org`, `log-done-empty-note.org` | `org-log-done 'note` | `todo.log_done = "note"` |
| `repeat-drops-plain-scheduled.org` | `org-log-repeat nil` | - |
| `repeat-drops-closed.org` | `org-log-done 'time` | `todo.log_done = "time"` |
| `ordered-*.org`, `done-to-done-children.org` | `org-enforce-todo-dependencies t` | organ's default (on) |
| `checkbox-in-child.org`, `done-to-done-checkbox.org` | `org-enforce-todo-checkbox-dependencies t` | `todo.enforce_checkbox_dependencies = true` |
| `log-into-drawer-property.org` | keywords `TODO(!) \| DONE(!)` | same sequence, `todo.log_into_drawer = false` |
| `log-order-not-reversed.org` | keywords `TODO(!) \| DONE(!)` | same sequence |
| `log-note-indentation.org` (`PROFILE: defaults`) | keywords `TODO(!) \| DONE(!)`, `org-log-into-drawer t` | same sequence, `todo.log_done = false` |
| `defaults-log-drawer.org` | keywords `TODO \| DONE(!)` | same sequence |
| `clock-into-drawer-nil.org` | `org-clock-into-drawer nil` | `clock.into_drawer = false` |
| `clock-into-drawer-integer.org` | `org-clock-into-drawer 2` | `clock.into_drawer = 2` |
| `clock-zero-time-removed.org` | `org-clock-out-remove-zero-time-clocks t` | no option (TD-45) |
| `clock-rounding.org` | `org-clock-rounding-minutes 5`, `NOW` 09:32 | no option (TD-45) |
| `clock-in-switch-state.org` | `org-clock-in-switch-to-state "NEXT"`, keywords `TODO NEXT \| DONE` | same sequence, no option (TD-46) |
| `reschedule-note-indent.org` | `org-log-reschedule 'note`, `org-log-into-drawer t` | `todo.log_reschedule = "note"` |
| `reschedule-log-time.org` | `org-log-reschedule 'time` | `todo.log_reschedule = "time"`, `todo.log_into_drawer = false` |
| `date-prompt-prefer-future-off.org` | `org-read-date-prefer-future nil` | no option (TD-92) |

## Option runs (`options.lua`)

| Run | organ setting | Cases | Ruling |
|-----|---------------|-------|--------|
| `log-done-off` | `todo.log_done = false` | `defaults-closed-on-done.org` | TD-33 KEEP+OPT |
| `log-into-drawer-off` | `todo.log_into_drawer = false` | `defaults-log-drawer.org` | TD-34 KEEP+OPT |
| `planning-indent-flush` | `todo.planning_indent = 0` | `defaults-clock-indent.org`, `defaults-planning-indent.org` | TD-68, TD-75 KEEP+OPT (the ruling's `indent.adapt_indentation = nil` folds this setting in) |

Each run shows no difference, which is what marks those IDs `pass`.
Emacs runs with its defaults in every option run.

## Coverage outside the diff (index.tsv)

- `pty`: TD-12 (multi-line note buffer), TD-36 (fast selection picker),
  TD-107 (editing in column view): interactive UI.
- `unit`: TD-4, TD-47, TD-72, TD-86, TD-115 (commands organ does not have
  yet); TD-49 (idle resolution choices, timer-driven), TD-50 (two-session
  clock persistence), TD-69 (typed date in the schedule picker), TD-117
  (countdown prompt and Effort default); TD-106 (column widths are display
  only; the gate compares values); TD-38 (the buffer already conforms,
  `clock-in-switch-task.org`; the FIX left is the notification text);
  TD-22 (the FIX part is doc text); TD-67 (the FIX part, reporting the
  error, is a message: no refusal on either side); TD-89 (the FIX part,
  not eating user text that looks like a duration, cannot be told from the
  kept idempotent re-run in one buffer).
- `option:`: TD-37 (saving on every state change) and TD-83 (month-end
  overflow) have no option yet.

## Signature notes

A row's class must be allowed by every ID it names, so a hunk that also
holds a KEEP contribution (TD-34 in `log-done-note.org`, TD-71 in
`schedule-prompt-default.org`) is keyed TRANSITIONAL with its FIX IDs and
the KEEP contribution is named in a `#` line above the row. Hunks where
Emacs rewrites property drawers during column view capture
(`columnview-dblock-*.org`) are keyed to TD-99, the write-back entry.

## Corpus provenance

Cases come from the audit fixtures in
`2026-10-18-emacs-divergence/todo-time/fx` with the operations of the
ledger repro:

| Cases | Source |
|-------|--------|
| `typ-todo-*`, `cycle-empty-returns-to-set`, `shift-left-right-sets`, `todo-*`, `tags-realign-after-keyword`, `log-*`, `repeat-*`, `ordered-*`, `checkbox-in-child`, `done-to-done-*`, `startup-logdone`, `startup-lognotedone`, `logging-property`, `priority-file-keyword`, `defaults-keyword-sequence`, `defaults-closed-on-done`, `defaults-log-drawer`, `defaults-dependencies`, `state-change-saves` | `fx/todo/*` (typ, fresh, seqs, inv, tags, late, inblk, mk1, ln1, rp1..rp4, rpx*, zero, skip, rpclk, dep1..dep3, st1..st5, lid, an2, pri, def1, cyc1, save) |
| `clock-*`, `clocktable-*`, `dblock-*`, `defaults-clock-indent` | `fx/clock/*` and `fx/clock/ct-body.txt` (one block per parameter the ledger probed; several blocks per case, updated together) |
| `schedule-*`, `startup-logreschedule`, `reschedule-*`, `defaults-planning-indent` | `fx/dates/s1..s5, s7, m4` |
| `shift-*` | `fx/dates/shift1.txt`, `shift2.txt`, one line per probed column |
| `eval-range-*` | `fx/dates/ev` and the ledger's inline repros |
| `date-prompt-*` | `fx/dates/inputs.txt`, `inputs-def.txt` |
| `effort-duration-forms` | `cv-dur-inputs.txt` |
| `set-effort-*`, `columns-*`, `columnview-dblock-*`, `timer-input-language` | `fx/cv/eff1..eff3, sum1, prop, types, special, scope, late, db1, db3, tm` (ITEM dropped from column formats except in `columns-item.org`, so its separate difference stays in one case) |
| `clock-in-before-heading`, `clock-in-switch-task`, `clocktable-block-matching`, `date-prompt-matching`, `eval-range-forms`, `reschedule-log-time`, `schedule-planning-placement`, `shift-matching`, `typ-todo-repeat-press` | the ledger's "Matches" lists: these pass |
