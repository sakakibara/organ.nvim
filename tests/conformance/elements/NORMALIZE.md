# Elements gate: output format, Emacs settings and normalization

Both sides print one line per element or object, in document order:

    <org-element type> <begin line>:<begin col>-<end line>:<end col> [key=value ...]

Lines are 1-based, columns are 0-based byte offsets. Values escape `\`,
TAB and newline as `\\`, `\t`, `\n`. Empty values are omitted. There is no
normalize.lua: both dumpers print the shared format directly, and every rule
below is applied by the dumper named.

## Multi-document cases

A case may hold several documents separated by lines of exactly `=====`
(the auditor's battery format). Each document is parsed on its own and
printed under a `##### N` header. Positions are relative to that document.
A case must not start with a separator line.

## Emacs settings (emacs.el)

- `org-todo-keywords` is organ's default sequence (TODO NEXT WAITING HOLD
  PROJ | DONE CANCELLED, `todo.sequence` in lua/organ/defaults.lua; kept by
  register workflow-1). Without it, Emacs -Q reads only TODO and DONE and
  every headline with another keyword differs for a reason no ruling covers.
- `org-inlinetask` is loaded. organ's grammar always reads 15-star lines as
  inline tasks; without the library Emacs reads them as headlines.
- `org-element-use-cache` is nil: each document is parsed once in a fresh
  buffer, so the cache can only add state, never information.
- `conformance-clock-pin` (contract); nothing printed depends on the clock.

## Extents

- An element begins at `:post-affiliated` (its affiliated keywords are
  reported as properties, below); an object at `:begin`. organ: the node's
  start.
- Both sides then move the begin forward past spaces, TABs and newlines and
  the end back past them. org-element attributes trailing blank lines and
  spaces to the node before them (`:post-blank`) and indentation to the
  node after; tree-sitter attributes them by its own extras rules. Whitespace
  at an extent's edge is no element's content. Blank lines that carry
  meaning (ending a list or footnote definition, detaching an affiliated
  keyword) still show: they change which element contains which, and the
  extents of the non-blank content.
- org-element ends a `citation-reference` after its `;` separator; the Emacs
  side drops that one trailing `;`. organ's node ends at the key or suffix.
  The separator belongs to the citation's syntax, not to the reference.
- Order: by begin, then by end descending (container first), then by each
  side's pre-order walk. An element and an object with the same extent print
  element first on both sides.

## Type mapping (organ.lua)

Block grammar: `zeroth_section`, `section` -> section; `headline`;
`inlinetask`; `planning`; `property_drawer` -> property-drawer;
`node_property` -> node-property; `drawer`; `greater_block` -> quote-block
or center-block by its name, else special-block with `type`;
`dynamic_block` -> dynamic-block; `src_block`, `example_block`,
`export_block`, `verse_block`, `comment_block`, `latex_environment`,
`fixed_width`, `horizontal_rule`, `diary_sexp`, `comment`, `clock`,
`paragraph`, `footnote_definition`, `keyword` -> the same org-element names;
`list` -> plain-list; `list_item` -> item; `table`; `table_row` and
`table_header_row` -> table-row type=standard; `table_rule` -> table-row
type=rule; `table_cell` -> table-cell; `affiliated_keyword` not followed by
an element and `formula` not after a table -> keyword. The headline line's
`cookie` field -> statistics-cookie (the grammar's only object node in a
title).

Inline grammar: `bold`, `italic`, `underline`, `code`, `verbatim`,
`entity`, `macro`, `subscript`, `superscript`, `target`, `citation`,
`statistics_cookie` -> same names; `strike` -> strike-through;
`latex_fragment`, `line_break`, `export_snippet`, `inline_src_block`,
`inline_babel_call`, `citation_reference` -> the hyphenated names;
`footnote_ref` -> footnote-reference; `link_regular`, `link_plain`,
`link_angle` -> link; `link_radio` (the `<<<x>>>` node) -> radio-target;
`timestamp_*` -> timestamp. `plain_text`, `inline_content` and field nodes
print nothing. Nodes org-element gives no contents (timestamps, code,
verbatim, entities, fragments, macros, snippets, inline src and calls,
cookies, targets, line breaks) are not walked into: their children are
fields, not objects.

## Structure the grammar groups differently

- Section of a headline: the grammar makes planning and the property drawer
  children of the headline and starts `section` after them; org-element's
  section starts at the planning line. organ.lua reports one section from
  the first of planning / property drawer / section to the end of the last.
  Org syntax defines the section as everything between the headline line and
  the next headline; both groupings hold the same lines.
- Affiliated keywords and `#+TBLFM:`: the grammar makes them siblings.
  organ.lua attaches them by organ's own consumer rule
  (lua/organ/ast/from_org.lua `emit_section_children`): affiliated keywords
  attach forward to the next element of the same container, TBLFM lines to
  the table right before them. The element's extent stays the grammar's, so
  a table's extent excludes its TBLFM lines on the organ side.
- Timestamps in planning and clock lines: org-element stores them as
  properties, not contents. The organ side drops the objects its injection
  produces inside planning and clock elements and prints planning values as
  properties instead, as Emacs does.

## Properties

- headline / inlinetask: `level todo priority commented tags title`. organ
  reads them from the grammar's headline fields; `todo` counts only when its
  text is one of organ's configured keywords (the test organ's highlighter
  applies through `org-todo-keyword?`); `title` is the text between the last
  keyword/priority/COMMENT and the tag list, trimmed, which is org-element's
  `:raw-value`. Priorities print as org 9.8 stores them: a value up to 64 as
  digits, otherwise the letter.
- `entry` lines (after the elements): one per headline, the same properties,
  organ side from organ's indexer (`organ.indexer.extract`, what agenda and
  search read). Two organ readers of headlines are checked against the same
  org-element values.
- `file-id` (last line): the ID of the zeroth section's property drawer as
  org-element sees it (PR-14 names org-element as the oracle; note that
  `org-entry-get` at point-min misses a drawer preceded by a blank line,
  which org-element still reads as a property drawer); organ side: the
  indexer's level-0 record.
- planning: `closed deadline scheduled` raw values. clock: `duration`.
  node-property: `key value`. drawer: `name`. src-block: `language`.
  export-block: `type`, upper-cased on both sides (back-end names are
  case-insensitive; org-element upcases). special-block: `type`.
  dynamic-block: `name`. keyword: `key` upper-cased, `value` trimmed;
  babel-call prints as key=CALL so it lines up with organ's keyword.
  footnote-definition: `label`. table: `type`, `tblfm` (count). table-row:
  `type`. diary-sexp: `value`.
- item: `bullet` (trimmed), `counter`, `checkbox` (on / off / trans),
  `tag` (raw text, trimmed; Emacs via `org-element-interpret-data`). An
  alphabetical counter prints as its ordinal on the organ side (`[@b]` ->
  2), the number org-element stores for it.
- Affiliated keywords on an element: `aff` = sorted keys (CAPTION HEADER
  NAME PLOT RESULTS and ATTR_*), plus `name` = the NAME value, compared
  literally. CAPTION objects print as objects at their positions.
- timestamp: `type` (active, inactive, active-range, inactive-range, diary).
  A single stamp holding a time range is `*-range` on both sides
  (org-element's `:type`; organ: a `ts_time_range` child).

Not compared: plain-list type, link type and path, and object properties
other than timestamp type (presence and extent carry the ledger's
differences). Keyword values other than CAPTION: org-element keeps them as
strings in the parse tree.
