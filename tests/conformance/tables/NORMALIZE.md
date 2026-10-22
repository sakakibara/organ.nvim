# tables gate: output shape, operations and Emacs settings

No normalize.lua: both sides print the same shape directly, and nothing is
rewritten after printing.

## Cases and operations

A case is an org file whose leading `# key: value` comment lines name the
operation (`# op: NAME ARGS`, default `recalc`) and the option runs it takes
part in (`# options: NAME`). Point starts at the `@@C@@` marker (removed
before the run) or at the start of the buffer. A `.csv`, `.tsv`, `.txt` or
`.dat` case is imported into a buffer holding one empty line, point at its
start: an nvim buffer always has a line, and an Emacs buffer of one newline
is the same file, so both sides insert into the same document.

Each operation is the command a user reaches for on each side:

| op | Emacs | organ |
|----|-------|-------|
| recalc | `org-table-recalculate t` (C-u C-c *) | `table.eval_formulas` |
| recalc-line | `org-table-recalculate nil` (C-c *) | `table.eval_formulas` (no single-line command) |
| iterate | `org-table-iterate` | `table.eval_formulas` (no iteration command) |
| ctrl-c-ctrl-c | `org-ctrl-c-ctrl-c` at point | `table.eval_formulas` at point |
| align | `org-ctrl-c-ctrl-c` in the table | `table.realign` |
| format | `org-table-map-tables` + `org-table-align` | `format.format_buffer` |
| tab / shift-tab | `org-cycle` / `org-shifttab` | `table.tab` / `table.shift_tab` |
| insert-row-above / -below | `org-table-insert-row` / with arg | `insert_row_above` / `insert_row_below` |
| delete-row, move-row-up/down | `org-table-kill-row`, `org-table-move-row-*` | `delete_row`, `move_row_*` |
| insert-column-left | `org-table-insert-column` | `insert_column_left` |
| delete-column, move-column-left/right | `org-table-delete-column`, `org-table-move-column-*` | `delete_column`, `move_column_*` |
| sort K | `org-table-sort-lines nil ?K` | `sort_by_current_column` (desc when K is upper case) |
| import F | `org-table-import F nil` (separator auto-detected) | `table_io.import` at the cursor line |
| export FMT | `org-table-export TMP "orgtbl-to-FMT"` | `table_io.export TMP.FMT` |

`recalc`, `align` and `export` first move point to the first table when it
is not already in one, on both sides. `align` and `tab` go through the key
commands rather than `org-table-align` / `org-table-next-field` because
those commands are where Emacs checks for a table.el table (TB-48); called
directly they realign table.el tables too, which no Emacs user sees.

## Output shape

The final buffer, one line per buffer line:

- A table row (a line starting with optional blanks and `|`) prints as `|`
  followed by its fields separated by TAB, each field trimmed of blanks.
  org reads a field as the text between two pipes without its padding
  (org-element's table-cell contents, `org-table-get-field`), so padding is
  alignment, not content; alignment is compared in the raw section below.
- An hline (a line starting with optional blanks and `|-`) prints as `|-`:
  every such line is a rule to org, whatever its dashes and plus signs.
- Every other line prints literally.

Then, in this order:

- `@ LINE:COL` for `tab` / `shift-tab`: point, COL counted in characters.
- `--- export` and the exported file's lines, for `export`.
- `--- raw` and the buffer lines unchanged, for the operations whose result
  is a layout: `align`, `format`, `tab`, `shift-tab`, `import`.

A first line `! error` records that the operation refused: an Emacs `error`
or `user-error` on one side, an organ `notify.error` or `notify.warn` on
the other. Message wording is not compared: R7 requires a message and an
unchanged buffer, not a spelling, and the buffer is compared in full.
Informational messages (`message`, `notify.info`) are not printed on either
side. A Lua error inside an organ command prints `! crash: MESSAGE`, with
the `file.lua:LINE:` prefix removed so the row survives unrelated edits; a
crash is never an expected refusal.

An option run prints `n/a` on both sides for every case whose `# options:`
line does not name it.

## Emacs settings

- `_clock.el` pins the time, as on every gate.
- `_collate.el` makes Emacs on macOS sort strings as it does on GNU/Linux,
  as on every gate: a `?a` sort ignores case.
- `(set-terminal-coding-system 'utf-8)`: the gate runs with `LC_ALL=C`, and
  in a C-locale batch session `org-string-width` measures every non-ASCII
  character by the width of its escape (two CJK characters measure 12), so alignment
  would follow a display no Emacs user has. With it, widths equal those of
  a UTF-8 session.
- `coding-system-for-read` / `-write` `utf-8`: cases and outputs are UTF-8,
  and the C locale would otherwise decide the coding from the environment.
- `yes-or-no-p` / `y-or-n-p` answer yes: `org-table-import` and
  `org-table-export` ask before importing an unusual extension or
  overwriting, which a batch run cannot answer. The confirmations
  themselves are XT-2 / XT-3, covered by unit rows in index.tsv.

## Option runs

- `emphasis`: organ `emphasis.enabled = true` (link and emphasis conceal on,
  Emacs's `org-link-descriptive` default). Emacs runs unchanged, since that
  is already its default. Cases: `align-link.org` (TB-46's FIX part: align
  by the concealed width when conceal is on).

## Keying notes

- `import-*` cases: organ's header rule after row 1 (TB-50 / IM-35, KEEP)
  sits next to row 2, so when row 1 or 2 also differs for a FIX entry, or
  when a column width differs (the raw section changes on every row), the
  two land in one hunk. Those hunks name only the FIX entry with class
  TRANSITIONAL, because a TRANSITIONAL row may not name a KEEP+OPT ID. The
  rule alone is keyed KEEP `TB-50,IM-35` wherever it forms its own hunk.
- TB-50's FIX part (escape `|` in a cell) is keyed to IM-38, the same
  defect, because TB-50's ruling string is KEEP+OPT.
