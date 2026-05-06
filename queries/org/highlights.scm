; ── Headline structural highlights ──────────────────────────────────
; The grammar now exposes todo/priority/title/tags/cookie as named
; children of `headline_line`. We capture each directly and
; `#org-todo-keyword?` (a config-aware predicate) classifies the
; todo keyword as active vs done.
(headline_line
  todo: (todo) @org.todo.active
  (#org-todo-keyword? @org.todo.active active))

(headline_line
  todo: (todo) @org.todo.done
  (#org-todo-keyword? @org.todo.done done))

; Priority cookie `[#A]` / `[#B]` / `[#C]`.
(headline_line priority: (priority) @org.priority)

; COMMENT marker (excludes subtree from agenda / export).
(headline_line comment: (comment_marker) @comment)

; Trailing tag block — capture every `tag` child for fine-grained styling.
(headline_line tag_list: (tag_list) @org.tag)
(headline_line tag_list: (tag_list (tag) @org.tag.name))

; Statistics cookie at end of heading: `[33%]` / `[1/3]`.
(headline_line cookie: (statistics_cookie) @org.cookie)

; Per-level heading highlight, scoped to the (stars) child AND the
; (title) child so the whole headline (stars + title text) renders
; in the level color — Emacs's behavior, and what users expect.
; Falls back to org.heading.<n> on the (title) so theme overrides
; flow naturally; the predicate selects by star count.
((headline_line stars: (stars) @org.heading.1)  (#org-stars-level? @org.heading.1 1))
((headline_line stars: (stars) @org.heading.2)  (#org-stars-level? @org.heading.2 2))
((headline_line stars: (stars) @org.heading.3)  (#org-stars-level? @org.heading.3 3))
((headline_line stars: (stars) @org.heading.4)  (#org-stars-level? @org.heading.4 4))
((headline_line stars: (stars) @org.heading.5)  (#org-stars-level? @org.heading.5 5))
((headline_line stars: (stars) @org.heading.6)  (#org-stars-level? @org.heading.6 6))
((headline_line stars: (stars) @org.heading.7)  (#org-stars-level? @org.heading.7 7))
((headline_line stars: (stars) @org.heading.8)  (#org-stars-level? @org.heading.8 8))
; Title gets the per-level title color.  We capture BOTH the stars
; and the title in the same match so the predicate can count stars
; (the level marker) while we apply the highlight to the title bytes.
((headline_line stars: (stars) @_s title: (title) @org.heading.title.1) (#org-stars-level? @_s 1))
((headline_line stars: (stars) @_s title: (title) @org.heading.title.2) (#org-stars-level? @_s 2))
((headline_line stars: (stars) @_s title: (title) @org.heading.title.3) (#org-stars-level? @_s 3))
((headline_line stars: (stars) @_s title: (title) @org.heading.title.4) (#org-stars-level? @_s 4))
((headline_line stars: (stars) @_s title: (title) @org.heading.title.5) (#org-stars-level? @_s 5))
((headline_line stars: (stars) @_s title: (title) @org.heading.title.6) (#org-stars-level? @_s 6))
((headline_line stars: (stars) @_s title: (title) @org.heading.title.7) (#org-stars-level? @_s 7))
((headline_line stars: (stars) @_s title: (title) @org.heading.title.8) (#org-stars-level? @_s 8))

; Inlinetask: same field set as headline.
(inlinetask_line
  todo: (todo) @org.todo.active
  (#org-todo-keyword? @org.todo.active active))
(inlinetask_line
  todo: (todo) @org.todo.done
  (#org-todo-keyword? @org.todo.done done))
(inlinetask_line priority: (priority) @org.priority)
(inlinetask_line comment: (comment_marker) @comment)
(inlinetask_line tag_list: (tag_list) @org.tag)
(inlinetask_line cookie: (statistics_cookie) @org.cookie)

; Title fallback (no per-level styling for inlinetasks).

; ── Drawers, properties, planning ───────────────────────────────────
; node_property exposes name + value; highlight each separately.
(property_drawer) @org.drawer
(node_property name:  (property_name)  @property)
(node_property value: (property_value) @org.property.value)

; Planning entries: keyword (SCHEDULED/DEADLINE/CLOSED) + timestamp.
; The base `@org.planning.keyword` capture is the broad fallback;
; the predicate-gated captures below override per-keyword so users
; can theme `SCHEDULED:` distinctly from `DEADLINE:` etc.
(planning_entry keyword:   (planning_keyword)   @org.planning.keyword)
(planning_entry timestamp: (planning_timestamp) @org.timestamp)
((planning_entry keyword: (planning_keyword) @org.planning.scheduled)
 (#match? @org.planning.scheduled "^[Ss][Cc][Hh][Ee][Dd][Uu][Ll][Ee][Dd]:?$"))
((planning_entry keyword: (planning_keyword) @org.planning.deadline)
 (#match? @org.planning.deadline "^[Dd][Ee][Aa][Dd][Ll][Ii][Nn][Ee]:?$"))
((planning_entry keyword: (planning_keyword) @org.planning.closed)
 (#match? @org.planning.closed "^[Cc][Ll][Oo][Ss][Ee][Dd]:?$"))

; Clock: start/end timestamps + duration.
(clock start:    (clock_timestamp) @org.timestamp)
(clock end:      (clock_timestamp) @org.timestamp)
(clock duration: (clock_duration)  @org.duration)

(planning) @org.planning

(drawer) @org.drawer

; Keywords (#+TITLE: …) and affiliated keywords (#+NAME: / #+CAPTION:)
; both decompose into name + value fields; expose them so consumers
; can style the directive name distinctly from its value.
(keyword) @org.keyword
(keyword name:  (directive_name)  @org.keyword.name)
(keyword value: (directive_value) @org.keyword.value)
; #+TITLE: gets its own face (Emacs `org-document-title`) so the
; document title stands out from #+CATEGORY / #+OPTIONS / etc.  We
; piggy-back on a query-time predicate that compares the directive
; name byte-text to "TITLE" (case-insensitive).
((keyword name: (directive_name) @_n value: (directive_value) @org.keyword.title)
 (#match? @_n "^[Tt][Ii][Tt][Ll][Ee]$"))

(affiliated_keyword) @org.keyword.affiliated
(affiliated_keyword name:  (directive_name)  @org.keyword.name)
(affiliated_keyword value: (directive_value) @org.keyword.value)

; `#+TBLFM:` is a `formula` node (separate from `keyword`) so editors
; can colour table formulas distinctly.
(formula) @org.formula
(formula name:  (directive_name)  @org.formula.name)
(formula value: (directive_value) @org.formula.value)

(paragraph) @org.body

; Comment: distinguish the `#` prefix line from the body text.
(comment) @comment
(comment_line body: (comment_body) @comment.body)

(section) @org.section

(list) @org.list
(list_item) @org.list.item
; Bullet (- / + / * for unordered; 1. / 1) for ordered) — Emacs
; renders these distinctly from list body text.  The grammar's
; `bullet:` field carries either form.
(list_item bullet: (bullet) @org.list.bullet)
; Checkbox token (`[ ]` / `[X]` / `[-]`) — Emacs colors the brackets
; + state char distinctly from the surrounding list text.
(list_item checkbox: (checkbox) @org.list.checkbox)

(table) @org.table
(table_row) @org.table.row
; Header row (followed by `|---|`) — distinct so themes can bold it.
(table_header_row) @org.table.header
(table_rule) @org.table.delimiter

; Whole-block highlights.  greater_block covers quote / verse /
; center / etc. — we gate on the begin-line text so themes can pick
; per-flavour faces.  src / example / export / verse / comment have
; their own dedicated grammar nodes already.
(src_block)     @org.block.src
(example_block) @org.block.example
(export_block)  @org.block.export
(verse_block)   @org.block.verse
(comment_block) @org.block.comment
(dynamic_block) @org.block.dynamic
; greater_block: dispatch by the begin-line keyword (`quote`,
; `verse`, `center`, custom user blocks).  The match runs on the
; whole-block text; first ~30 chars cover any reasonable
; `#+begin_<name>` keyword.
((greater_block) @org.block.quote
 (#match? @org.block.quote "^[ \t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Qq][Uu][Oo][Tt][Ee]"))
((greater_block) @org.block.center
 (#match? @org.block.center "^[ \t]*#\\+[Bb][Ee][Gg][Ii][Nn]_[Cc][Ee][Nn][Tt][Ee][Rr]"))
; Fallback: any other greater_block flavour gets the generic face.
(greater_block) @org.block

; src/example/export/verse block prefix decomposition: language token
; + header arguments are exposed as fields.
(src_block language:        (src_block_language)   @org.block.language)
(src_block header_args:     (block_header_args)    @org.block.header_args)
(example_block header_args: (block_header_args)    @org.block.header_args)
(export_block header_args:  (block_header_args)    @org.block.header_args)
(verse_block header_args:   (block_header_args)    @org.block.header_args)

(dynamic_block) @org.block.dynamic

(latex_environment) @org.latex

(footnote_definition) @org.footnote
(footnote_definition label: (footnote_label) @org.footnote.label)

(horizontal_rule) @org.hr

; Fixed-width block + per-line body field.
(fixed_width) @org.fixed_width
(fixed_width_line body: (fixed_width_body) @org.fixed_width.body)

(clock) @org.clock

(diary_sexp) @org.diary_sexp
(diary_sexp body: (diary_sexp_body) @org.diary_sexp.body)

(inlinetask) @org.inlinetask

(zeroth_section) @org.section
