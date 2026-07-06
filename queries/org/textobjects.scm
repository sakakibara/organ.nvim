; nvim-treesitter-textobjects reads `queries/<lang>/textobjects.scm`.
; org's structure has no honest slot in the code-oriented standard capture
; set (a heading is not a function), so captures are namespaced @org.* to
; match this plugin's highlight convention.  See doc/organ.txt for a
; recommended keymap block that wires these to keys.
;
; Blocks are the one exception: a block genuinely IS a `@block`, so those
; also carry the standard capture to light up existing block keymaps.
;
; Only nodes the grammar actually exposes get captured.  src/example block
; bodies are anonymous tokens (no named node), so blocks are outer-only --
; textobjects inside a src block come from the injected language's own query.

; Subtree: whole heading incl. body and child subtrees; inner is the
; heading's own body (the `section` node), excluding the heading line and
; any nested subtrees.
(headline) @org.subtree.outer
(headline (section) @org.subtree.inner)

; The heading line itself; inner is just the title text.
(headline_line) @org.heading.outer
(headline_line (title) @org.heading.inner)

; Lists and list items.
(list) @org.list.outer
(list_item) @org.item.outer
(list_item (paragraph) @org.item.inner)

; Tables, rows, cells.
(table) @org.table.outer
(table_row) @org.row.outer
(table_cell) @org.cell.outer

; Blocks -- dual-tagged so existing @block.outer keymaps work in org too.
[
  (src_block)
  (example_block)
  (verse_block)
  (export_block)
  (comment_block)
  (greater_block)
  (dynamic_block)
] @org.block.outer @block.outer
