# editing gate: cases, output shape and Emacs settings

No normalize.lua: both sides print the same shape directly, and nothing is
rewritten after printing.

## Cases

A case is an org buffer preceded by `# key: value` header lines:

- `# op: NAME ARGS` names the operation (table below). Arguments are
  words; a double-quoted argument may hold spaces (`"BAD KEY"`, `""`).
- `# setup: NAME` turns on a named setting on both sides (below).
- `# options: NAME` makes the case take part in that option run.

The header lines are not part of the buffer: both sides strip every
leading `# key: value` line before loading it. `@@C@@` marks point and
`@@M@@` the mark; both markers are removed before the operation runs, and
point starts at the beginning of the buffer when there is no `@@C@@`.
A `PP` in a cut-paste / copy-paste case marks where the subtree is
pasted; it is part of the buffer until the operation removes it.

The Emacs side loads the text into a fresh org-mode buffer. The organ side
writes it to a temporary `.org` file and opens that file in a new tab, so
the ftplugin, startup folding and the indexer see a real org buffer.

## Output

1. `! error` when the operation signals an error (Emacs `error` /
   `user-error`; organ: a Lua error, a returned error string, or an
   `organ.notify` error or warning). The wording of error messages is not
   compared: each side words them its own way. `! no organ command` when
   organ has no command for the operation (the Emacs side runs it).
2. Buffer operations print the buffer, one line per line. Visibility
   operations (sparse trees, startup, overview, Tab cycling, global cycle,
   speed keys) print each line as `V|text` or `H|text` instead. Emacs: a
   line is hidden when its first character is invisible. organ: a line is
   hidden when it lies inside a closed fold other than as the fold's first
   line (that line is what the user sees, as fold text) or under a
   `conceal_lines` extmark (organ's CONTENTS view).
3. `--- point` and `LINE:COL` (1-based line, 0-based column in characters)
   for every buffer and visibility operation except `fill` and `format`;
   `mark LINE:COL` follows when Emacs leaves an active region
   (`mark-subtree`).
4. Value operations print only their value lines: `allowed-values` (one
   `%S`-quoted string per line, `nil` for none), `inherited-property` (the
   quoted value or `nil`), `inherited-property-all` and `inherited-tags`
   (`LINE<TAB>VALUE` for every headline), `org-indent` (`lp=WIDTH|text`,
   the virtual prefix width in columns), `narrow` (the narrowed text).

Point and cursor are the same position written two ways: Emacs's point
lies between characters, Vim's cursor on one. Column N is point before
character N, which is the cursor on character N. Point at the end of a
non-empty line has no normal-mode cursor cell, so the organ window uses
`virtualedit=onemore`, the Vim setting that admits a cursor after the last
character; a case whose `@@C@@` ends a line then starts both sides at the
same place. organ's insert commands end by calling `startinsert!`, which
moves the cursor after the last character once Insert mode starts; the
harness records that call and reports the column Insert mode starts at.

`fill` and `format` print no point. `fill` is Vim's `gqip`, whose cursor
placement (on the last formatted line) is the operator's documented
contract, not organ's; `format` on the Emacs side is a parse / interpret
round trip that rebuilds the buffer, so its point means nothing.

`inherited-tags` prints each headline's tag set sorted. The operation
compares which tags a headline inherits; tag order inside the set is not
inheritance and differs only in how each side lists direct and inherited
tags.

## Operations

| op | Emacs | organ |
|----|-------|-------|
| meta-return | `org-meta-return` | `:Org meta_return` |
| insert-todo / insert-heading-rc / insert-todo-rc | `org-insert-todo-heading` / `org-insert-heading-respect-content` / `org-insert-todo-heading-respect-content` | `insert_todo` / `insert_heading_respect_content` / `insert_todo_heading_respect_content` |
| insert-subheading | `org-insert-subheading` | none |
| promote / demote | `org-promote-subtree` / `org-demote-subtree` | `promote` / `demote` |
| promote-headline / demote-headline | `org-do-promote` / `org-do-demote` | `promote_headline` / `demote_headline` |
| demote-region | `org-do-demote` with the region active | `structure.demote_region` over the region's lines |
| move-up / move-down | `org-move-subtree-up` / `-down` | `move_up` / `move_down` |
| toggle-comment | `org-toggle-comment` | `toggle_comment` |
| cut-paste / copy-paste | `org-cut-subtree` / `org-copy-subtree`, then `org-paste-subtree` at `PP` | `cut_subtree` / `copy_subtree`, then `paste_subtree` at `PP` |
| narrow | `org-narrow-to-subtree` | `narrow_to_subtree` |
| mark-subtree | `org-mark-subtree` | none |
| sort-entries K [PROP] | `org-sort-entries nil ?K` | `sort_entries K` (`property PROP` for `r`) |
| cycle-bullet [previous] | `org-cycle-list-bullet` | `list cycle_bullet` |
| item-indent / item-indent-tree / item-outdent-tree | `org-metaright` / `org-shiftmetaright` / `org-shiftmetaleft` | `demote_headline` / `demote` / `promote` (their list-item branch) |
| item-indent-region | `org-shiftmetaright` with the region active | `list.shift_region` over the region's lines |
| item-move-down | `org-move-item-down` | `move_down` (its list-item branch) |
| list-repair / format-list | `org-list-repair` | `list repair` / `format` |
| list-sort K | `org-sort-list nil ?K` | `list sort` (`alpha`, `numeric`, else K) |
| list-to-subtree | `org-list-make-subtree` | `list to_subtree` |
| toggle-checkbox / -remove / -region | `org-toggle-checkbox` / with `C-u` / with the region active | `toggle_checkbox` / none / `:N,MOrg toggle_checkbox` |
| update-statistics / todo | `org-update-statistics-cookies t` / `org-todo` | `update_statistics` / `todo` |
| set-property / delete-property | `org-set-property` / `org-delete-property` | `property.set` / `property.delete` |
| allowed-values K | `org-property-get-allowed-values nil K` | `property.allowed_values` |
| inherited-property K | `org-entry-get nil K t` | `element.property_value_inherited` at the headline |
| inherited-property-all K | the same at every headline | the same at every headline |
| inherited-tags | `org-get-tags` at every headline | the query layer: `indexer.index_file_sync`, then `query.headlines` with `include_inherited_tags` |
| fast-tags KEYS | `org-set-tags-command`, KEYS then RET as input | `set_tags`, KEYS then RET from `getcharstr` |
| set-tags / align-tags | `org-set-tags` / `org-align-tags t` | `tag_writer.write` / `format` |
| sparse-todo / sparse-todo-keyword KW | `org-show-todo-tree` / with `C-u`, KW as the answer | `sparse_tree todo` [KW] |
| sparse-tag / sparse-occur / sparse-match / sparse-match-todo | `org-match-sparse-tree` / `org-occur` / `org-match-sparse-tree` / with TODO-ONLY | `sparse_tree tag` / `regex` / `match` / `match M/!` |
| startup | `org-cycle-set-startup-visibility` | the ftplugin's startup state on open |
| overview / overview-cycle N | `org-overview`, then N `org-cycle` on line 1 | `fold.apply_overview`, then N `fold.cycle` on line 1 |
| tab / global-cycle | `org-cycle` / `org-global-cycle` after startup | `fold.cycle` / `fold.cycle_global` |
| emphasize C | `org-emphasize` (region when `@@M@@` is set; `SPC` removes) | `emphasize C`, or `emphasize.span` over the region |
| fill | `fill-paragraph` (`fill-column` 70) | `gqip` with `textwidth` 70 |
| tempo | `tempo-complete-tag` after `<KEY` | `tempo.expand` with the cursor after `<KEY` |
| structure-template TYPE | `org-insert-structure-template` over the region | none |
| priority-shiftup / -shiftdown | `org-shiftup` / `org-shiftdown` | `decrement` / `increment` (organ raises a priority with `<C-x>`) |
| timestamp-shiftup / -shiftdown | `org-shiftup` / `org-shiftdown` | `increment` / `decrement` |
| priority-up / priority-down | `org-priority 'up` / `'down` | `inline_edit.raise_priority` / `lower_priority` |
| format | `org-element-interpret-data` of the parse | `format` |
| toggle-heading / toggle-item | `org-toggle-heading` / `org-toggle-item` (region when `@@M@@` is set) | `toggle_heading` / `toggle_item` (`:N,MOrg` with a region) |
| indent-region | `indent-region` over the buffer | `gg=G` |
| org-indent | `org-indent-mode` `line-prefix` widths | `indent.attach` virtual-text widths |
| speed KEY | the `org-speed-commands` entry for KEY at the headline | the `speed.commands` entry for KEY through `speed.dispatch` |

An operation organ has no command for prints `! no organ command` and the
unchanged buffer. A region is the lines from point's line to the mark's
line; a mark at the start of a line ends the region on the line above,
as in Emacs.

## Emacs settings (emacs.el)

- `org-todo-keywords` is organ's default sequence (TODO NEXT WAITING HOLD
  PROJ | DONE CANCELLED, `todo.sequence` in lua/organ/defaults.lua; kept by
  register workflow-1). Without it every keyword other than TODO and DONE
  differs for a reason no ruling covers.
- `org-tempo` is loaded: organ's structure templates are on by default
  (XT-21), and `org-tempo` is where Emacs defines the same feature.
- `org-use-speed-commands` is t inside the speed operation only: the
  operation compares the key tables, and organ's own `speed.enabled` is
  bypassed the same way by calling `speed.dispatch`.
- Prompts get a fixed answer instead of reading stdin: `yes-or-no-p` and
  `y-or-n-p` answer yes, `read-file-name` answers `include.org` (the
  `<I` template), `completing-read` / `read-string` answer the keyword of
  `sparse-todo-keyword`.
- `conformance-clock-pin` (contract): the CLOSED stamps the TODO cycling
  of `priority-shiftup` writes depend on the clock.

Named setups (`# setup:`), each with the setting on both sides that the
ledger repro used:

| setup | Emacs | organ |
|-------|-------|-------|
| adapt-t | `org-adapt-indentation` t | `indent.adapt_indentation = true` |
| adapt-hd | `org-adapt-indentation` `headline-data` | `indent.adapt_indentation = "headline-data"` |
| odd-levels | `org-odd-levels-only` t | `structure.odd_levels_only = true` |
| split | default (`org-M-RET-may-split-line` is on) | `meta_return.split_headline` / `split_item = true` |
| tags-column-40 | `org-tags-column` 40 | `format.headline.tags_column = 40` |
| respect-content | `org-insert-heading-respect-content` t | default (organ always respects content) |
| alpha-lists | `org-list-allow-alphabetical` t | none (ED-28) |
| modify-bullet, modify-bullet-dash | `org-list-demote-modify-bullet` | none (ED-30) |
| checkbox-flat | `org-checkbox-hierarchical-statistics` nil | none (ED-40) |
| todo-flat | `org-hierarchical-todo-statistics` nil | none (ED-40) |

## Option runs

- `planning-flush` (ED-44): organ `todo.planning_indent = 0`, the setting
  that writes new planning lines and drawers flush left, as Emacs's
  default `org-adapt-indentation` nil. Emacs runs unchanged.
