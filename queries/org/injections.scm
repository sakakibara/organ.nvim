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
; The parser body (between the begin and end fences) is injected into the
; LANG parser if one is installed.  We use static `#match?` patterns per
; language so injections work even when no organ Lua module has loaded —
; this matters for headless `nvim -l` test scripts and for users who
; load organ.nvim lazily without `setup()`.
;
; To support an additional language, add a new pattern below.  Match is
; case-insensitive on the LANG token; tokens that aren't listed fall back
; to no injection (the body is still highlighted as plain `lblock_body`).

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Pp][Yy][Tt][Hh][Oo][Nn]")
 (#set! injection.language "python"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Ll][Uu][Aa]")
 (#set! injection.language "lua"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+([Bb][Aa][Ss][Hh]|[Ss][Hh]|[Ss][Hh][Ee][Ll][Ll]|[Zz][Ss][Hh])\\b")
 (#set! injection.language "bash"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+([Jj][Ss]|[Jj][Aa][Vv][Aa][Ss][Cc][Rr][Ii][Pp][Tt])\\b")
 (#set! injection.language "javascript"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+([Tt][Ss]|[Tt][Yy][Pp][Ee][Ss][Cc][Rr][Ii][Pp][Tt])\\b")
 (#set! injection.language "typescript"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Rr][Uu][Ss][Tt]")
 (#set! injection.language "rust"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Gg][Oo]\\b")
 (#set! injection.language "go"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Rr][Uu][Bb][Yy]")
 (#set! injection.language "ruby"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Cc]\\b")
 (#set! injection.language "c"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+([Cc][Pp][Pp]|[Cc]\\+\\+)\\b")
 (#set! injection.language "cpp"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Jj][Aa][Vv][Aa]\\b")
 (#set! injection.language "java"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+([Hh][Tt][Mm][Ll]|[Hh][Tt][Mm])\\b")
 (#set! injection.language "html"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Cc][Ss][Ss]")
 (#set! injection.language "css"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+([Yy][Mm][Ll]|[Yy][Aa][Mm][Ll])")
 (#set! injection.language "yaml"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Jj][Ss][Oo][Nn]")
 (#set! injection.language "json"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Tt][Oo][Mm][Ll]")
 (#set! injection.language "toml"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+([Mm][Dd]|[Mm][Aa][Rr][Kk][Dd][Oo][Ww][Nn])")
 (#set! injection.language "markdown"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Ss][Qq][Ll]")
 (#set! injection.language "sql"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+([Ee][Ll]|[Ee][Mm][Aa][Cc][Ss]-[Ll][Ii][Ss][Pp]|[Ee][Ll][Ii][Ss][Pp])")
 (#set! injection.language "elisp"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+([Vv][Ii][Mm]|[Vv][Ii][Mm][Ss][Cc][Rr][Ii][Pp][Tt])")
 (#set! injection.language "vim"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+([Hh][Aa][Ss][Kk][Ee][Ll][Ll]|[Hh][Ss])")
 (#set! injection.language "haskell"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Pp][Hh][Pp]")
 (#set! injection.language "php"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Pp][Ee][Rr][Ll]")
 (#set! injection.language "perl"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Ss][Ww][Ii][Ff][Tt]")
 (#set! injection.language "swift"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+([Kk][Oo][Tt][Ll][Ii][Nn]|[Kk][Tt])")
 (#set! injection.language "kotlin"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Ss][Cc][Aa][Ll][Aa]")
 (#set! injection.language "scala"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Rr]\\b")
 (#set! injection.language "r"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Dd][Oo][Tt]\\b")
 (#set! injection.language "dot"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Dd][Oo][Cc][Kk][Ee][Rr][Ff][Ii][Ll][Ee]")
 (#set! injection.language "dockerfile"))

((src_block) @injection.content
 (#match? @injection.content "^[ \\t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc][ \\t]+[Mm][Aa][Kk][Ee][Ff][Ii][Ll][Ee]")
 (#set! injection.language "make"))
