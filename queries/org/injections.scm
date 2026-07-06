; queries/org/injections.scm
;
; Inject tree-sitter-org-inline into block-grammar nodes that hold inline content.
; The #match? predicate skips plain-text-only content (no inline-construct opener
; bytes), avoiding unnecessary inline parser invocations.

((paragraph) @injection.content
 (#set! injection.language "org_inline")
 (#match? @injection.content "[*/_+=~\\[<\\\\{@$^]"))

((headline) @injection.content
 (#set! injection.language "org_inline")
 (#match? @injection.content "[/_+=~\\[<\\\\{@$^]|\\*[^ *\\n\\t\\r]"))

((list_item) @injection.content
 (#set! injection.language "org_inline")
 (#match? @injection.content "[*/_+=~\\[<\\\\{@$^]"))

((table_row) @injection.content
 (#set! injection.language "org_inline")
 (#match? @injection.content "[*/_+=~\\[<\\\\{@$^]"))

; Inject inline grammar into timestamp ranges so consumers get
; `timestamp_active` / `timestamp_inactive` / `timestamp_range_*`
; with all sub-fields (`ts_date`, `ts_dayname`, `ts_time`,
; `ts_time_range`, `ts_repeater`, `ts_repeater_filter`,
; `ts_repeater_alarm`, `ts_warning`) as direct named children.
((planning_timestamp) @injection.content
 (#set! injection.language "org_inline"))

((clock_timestamp) @injection.content
 (#set! injection.language "org_inline"))

; ---------------------------------------------------------------------------
; Embedded language inside #+begin_src LANG ... #+end_src.
;
; The LANG token is used directly as the injection language, so the body
; highlights with ANY tree-sitter parser installed in the user's Neovim --
; not a fixed list.  Neovim resolves the token against installed parsers
; and registered aliases; organ registers the org-babel spellings that
; differ from parser names (sh -> bash, emacs-lisp -> elisp, js ->
; javascript, ...) in setup() via `organ.ts_lang`.  An unknown token falls
; back to no injection -- the body still renders as plain block text.
((src_block
   (src_block_language) @injection.language)
 @injection.content)
