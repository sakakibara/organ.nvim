# Agenda gate: case format, settings and normalization

The gate renders agenda views of each case through Emacs (`emacs.el`,
org-agenda) and through organ (`organ.lua`, `organ.agenda`) and diffs the
two texts per case. Run it with
`TZ=UTC LC_ALL=C nvim --headless -l tests/conformance/agenda/gate.lua`.

## Case format

A case is one file in `cases/`. Leading header lines configure the run;
`#+CONFORMANCE-FILE: NAME` lines split the rest into the org files of the
case, written to a fresh directory under their names (the file name is the
default category on both sides). Header keys:

| Key | Meaning |
|-----|---------|
| `VIEW` | One view to render, in order (repeatable); see below. |
| `NOW` | `YYYY-MM-DD HH:MM` (UTC) both clocks are pinned to; default `2026-05-04 09:30`. |
| `TODO` | Space-separated keyword sequence (`A B \| C`) used instead of the default set, on both sides. |
| `HABITS` | Habit display on: Emacs loads `org-habit`, organ sets `agenda.show_habit_graphs = true`. |
| `EMACS` | One `(VARIABLE FORM)` binding for the Emacs side (repeatable). |
| `ORGAN` | One Lua statement mutating `cfg` (organ's config) for the organ side (repeatable). |
| `OPTIONS` | Space-separated option runs this case takes part in. |

Views and the call on each side:

| View | Emacs | organ |
|------|-------|-------|
| `day [DATE]` | `(org-agenda-list nil DATE 'day)` | `day()`; with DATE, `open(default_view + {from=DATE, to=DATE})` |
| `week [DATE]` | `(org-agenda-list nil DATE 'week)` | `week()`; with DATE, the Monday-anchored week of DATE |
| `month DATE` | `(org-agenda-list nil DATE 'month)` | `open(default_view + {span="month", start_day=DATE})` |
| `default` | `(org-agenda-list)` | `open(default_view)` (the dispatcher's default entry) |
| `todo` | `(org-todo-list)` | `todos()` |
| `tags Q` / `tags-todo Q` | `(org-tags-view nil/t Q)` | `tags(Q)` / none: organ has no tags-todo view and writes `(no tags-todo view)` |
| `search Q` | `(org-search-view nil Q)` | `search(Q)` |
| `stuck` | `(org-agenda-list-stuck-projects)` | `stuck()` |
| `composite` | custom command `((agenda "" ((org-agenda-span 'day))) (alltodo "") (tags "home"))` | blocks: day (default view), Global TODOs (as `todos()`), tag match `home` |

Output per view: a `=== VIEW` line, then the agenda buffer's lines, then a
`--- footer` line (see Normalization). A view that signals writes
`ERROR: <message>` (Emacs aborts the agenda on an invalid habit, TD-111).
An option run renders only the cases listing that option; every other
case writes `(not in the OPTION run)` on both sides.

## What each side shows

- Emacs: the buffer's visible text. Characters with an `invisible`
  property are dropped, as the window does not show them (link markup,
  AG-47). The buffer's final newline terminates its last line; it is not
  a blank line.
- organ: the buffer's lines plus virtual text where the window draws it.
  `right_align` virtual text (tags, the overflow marker) is placed flush
  with the window's last column; when the line is too long it covers the
  end of the line, as on screen. `eol` virtual text follows one space after
  the line.
- Width: organ's window is 79 columns. Emacs lays out the agenda against
  `window-max-chars-per-line`, which is 79 in an 80-column batch frame
  (the last column holds the continuation glyph); organ's window has no
  such column, so 79 columns gives both sides the same usable width. Tags
  flush right then end in the same column on both sides.
- Clock: both sides load `../_clock` and pin "now" to the case's `NOW`.
  organ's `organ.query.dates._now` is pointed at the pinned `os.time`,
  because that module captures `os.time` when it is loaded.

## Normalization (`normalize.lua`)

1. Trailing blanks are removed from every line on both sides. An agenda
   window does not display them; Emacs leaves one where a timestamp was
   cut out of a title (`Meeting <...>` becomes `Meeting `).
2. organ's keymap footer (a blank line plus `render.FOOTER_LINES`, the
   last lines of every agenda buffer while `agenda.footer` is on) is moved
   from the end of each view into a `--- footer` section after it; the
   Emacs side gets an empty `--- footer` section. The footer is still
   compared in full and shows up as its own hunk (see TRIAGE.md); moving
   it keeps it from merging with differences in the view's last rows.

Nothing else is normalized: blank lines, grid lines, leaders, dates,
counts and tag strings compare literally.

## Settings

Emacs (`emacs.el`), for every case:

| Setting | Reason |
|---------|--------|
| `org-todo-keywords` = organ's default sequence (`TODO NEXT WAITING HOLD PROJ \| DONE CANCELLED`) | Both sides must agree on what a keyword is; the same value as the other gates. A case's `TODO` header replaces it on both sides. |
| `org-agenda-files` = the case's files, in case order | organ's `agenda_files` is set to the same list; file order is the category-keep order. |
| `system-time-locale` = `"C"` | English day and month names, as organ prints. |
| `(require 'org-habit)` for `HABITS` cases only, run after all other cases | Habit display is opt-in on both sides (register agenda-8); org-habit cannot be unloaded, so the other cases run first. |

organ (`organ.lua`), for every case: `setup{org_dir = <temp>, notify =
false, scan_on_startup = false, debounce_ms = 0, watcher = {enabled =
false}}` only isolates the run and has no effect on rendering;
`agenda.sticky = false` gives every view a fresh buffer, as Emacs's
default `org-agenda-sticky` nil does; `agenda_files` = the case's files.
Every other value is organ's default. Indexed files are forgotten and the
config restored after each case.

Per-case settings (the same setting on both sides, from the ledger repro):

| Case | Emacs | organ | Reason |
|------|-------|-------|--------|
| `parity-week.org` | `TODO` header | `TODO` header | The retired parity test's keyword set (`TODO NEXT WAIT PROJ \| DONE CANCELLED`). |
| `habit-history.org` | `TODO TODO \| DONE` | same | TD-112: CANCELLED must not be a done keyword, as in the ledger's default-keyword repro. |
| `todo-sublevels.org` | `org-agenda-todo-list-sublevels nil` | `agenda.todo_list_sublevels = false` | AG-28 repro. |
| `todo-ignore-scheduled.org` | `org-agenda-todo-ignore-scheduled 'future` | `agenda.todo_ignore_scheduled = "future"` | AG-29 repro. |
| `log-mode.org` | `org-agenda-start-with-log-mode t` | `agenda.log_mode.on_start = true` | AG-39 repro. |
| `prefix-format.org` | `org-agenda-prefix-format` with Emacs's agenda/todo strings | `agenda.prefix_format` with the same strings | AG-48 repro. |
| `stuck-setup-level.org` | none (Emacs default `org-stuck-projects`) | `stuck` deep-merged as `setup` merges it, with `project_filter = {level = 2, todo = {exclude = {"DONE"}}}`, `next_states = {"TODO", "NEXT", "NEXTACTION"}` | AG-38: the setup-level form that should express Emacs's default. |
| `habit-*.org`, `habits-graph.org` | `HABITS` | `HABITS` | AG-50, TD-110..114 need habit display on both sides. |

## Option runs (`options.lua`)

| Run | organ setting | Ruling |
|-----|---------------|--------|
| `prewarning-if-scheduled` | `agenda.skip_deadline_prewarning_if_scheduled = false` | AG-9 KEEP+OPT: the option should reach Emacs. |
| `show-done` | `agenda.default_view.todo = {}` | AG-10 KEEP+FIX: showing DONE items is the option. |
| `inline-tags-no-marker` | `agenda.tags_virt_align = false`, `agenda.tags_overflow_marker = false` | AG-18 KEEP+FIX: the 2-space gap (the FIX part) is visible only on the inline path without the marker, as in the ledger repro. |

Emacs runs with its defaults in every option run.

## Coverage outside the diff (index.tsv)

- `option:unpadded-todo-keyword` (AG-19) and `option:category-column-fixed`
  (AG-41): the KEEP+OPT option does not exist yet.
- `option:prewarning-if-scheduled` (AG-9): the run exists but shows a
  difference that is in TRIAGE.md.
- `unit`: AG-10's FIX part (hide by the done-keyword set, not by name)
  produces no Emacs difference; XT-15 (`todo_keyword_format` "%-1s") is
  not visible in rendered text; TD-110 (habit alarm window) lives in
  org-habit's graph faces, not in its text.
- `pty`: AG-49 (filter keys) is interactive.
- XT-14 is `pass`: the `default` view records organ's today..+7d window,
  and the `week` view of the same case is Emacs's Monday-anchored week.

## Signature notes

A row's class must be allowed by every ID it names, so a hunk that also
contains a KEEP-only contribution (AG-9, AG-19, AG-41, XT-14) is keyed
TRANSITIONAL with its FIX IDs, and the KEEP contribution is named in a
`#` comment line above the row.

## Corpus provenance

Cases come from the audit fixtures (`2026-10-18-emacs-divergence/agenda/fx`
and `todo-time/fx/cv/hab*`) and from `tests/fixtures/parity`:

| Case | Source | Changes |
|------|--------|---------|
| `parity-week.org` | `tests/fixtures/parity/{habits,playground,tasks}.org` | Files in directory order, as the parity snapshot listed them. |
| `mixed-planning.org`, `mixed-planning-midweek.org` | `fx/b1` | none |
| `done-items.org`, `tag-overflow.org`, `inline-tag-column.org` | `fx/b1` | Subsets for the option runs. |
| `categories.org`, `long-category.org` | `fx/c1`, `fx/c2` | none |
| `deadline-warnings.org`, `repeaters.org` | `fx/d1` | Split in two; the headlines are unchanged. |
| `prewarning-if-scheduled.org` | `fx/d1` | One headline, for the option run. |
| `timed-entries.org` | `fx/g1` | none |
| `habits-plain.org`, `habits-graph.org` | `fx/h1` | none |
| `malformed-planning.org` | `fx/k1` | none |
| `todo-keywords.org`, `todo-sublevels.org` | `fx/k2`, `fx/k3` | none |
| `todo-ignore-scheduled.org` | `fx/k4` | Dates moved around the default pinned day (the audit needed the real date; the pinned clock covers `time-to-days`). |
| `log-mode.org`, `month-span.org`, `year-boundary.org` | `fx/l1`, `fx/m1` | none |
| `search-words.org`, `stuck-default.org`, `stuck-setup-level.org` | `fx/s1`, `fx/st` | none |
| `tags-matching.org`, `composite.org` | `fx/t1` | Property drawers (Effort, COLOR) removed so the effort suffix in TRIAGE.md stays in `effort-display.org`. |
| `prefix-format.org` | `fx/b1/work.org`, `fx/t1/a.org` | none |
| `diary-sexps.org`, `holidays.org` | `fx/x1`, `fx/x2` | none |
| `habit-history.org` | `todo-time/fx/cv/hab`, `hab2` | Invalid habits moved to their own cases; `NOW` 2026-05-06 so every habit is due. |
| `habit-no-repeat.org`, `habit-bad-window.org`, `habit-window.org` | `todo-time/fx/cv/hab`, `hab3` | One invalid habit per case: Emacs aborts on the first. |
| `default-window.org`, `empty-day.org`, `effort-display.org` | new | XT-14, AG-32, and the effort suffix. |
