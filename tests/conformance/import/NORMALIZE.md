# Import gate: oracle, settings and normalization

## Oracle and the two sides

Emacs has no Markdown importer, so this gate does not compare organ with an
Emacs importer. It compares what a Markdown document means with what organ's
import of it means to org:

- Reference side ("emacs" in the runner, `-` lines in hunks): the expected
  HTML each case carries. `emacs.el` (`conformance-run`) only writes it out.
- Organ side (`+` lines): `organ.lua` runs `:Org import markdown <file>`
  exactly as a user does (the command's own file read, `from_md`, `to_org`,
  and the buffer it opens), takes the buffer text, and has Emacs export it
  with `org-export-string-as ... 'html t` (`emacs.el`,
  `conformance-import-export`).

Design: the runner gives each side one function, and organ's side has to
pass through Emacs, because the question is what org reads in organ's
output. `organ.lua` therefore starts one `emacs -Q --batch` per case (one
case is one spec section, so one process exports all of its examples).
That keeps the runner contract unchanged and costs about 0.2 s per case.
The alternatives were rejected. Batching the whole corpus into one Emacs
run would make `render(path)` depend on the other cases. Having `emacs.el`
start nvim to import would put organ's side in the Emacs process and copy
the gate bootstrap.

## Corpus

- `commonmark-*.md`: the 652 CommonMark 0.31.2 examples. `gfm-*.md`: the
  24 GFM extension examples. Both are generated from the spec data already
  in the repo (`tests/fixtures/commonmark/spec.json`,
  `tests/fixtures/gfm/spec.json`), one file per spec section, in the
  spec's own example format (Markdown, a `.` line, the expected HTML,
  between 32-backtick fences). Real tabs are kept; no `->` substitution.
  Only the fenced blocks are read; `## <label>` names the example.
- The other cases are the audit's 83-case custom corpus plus the IM-1
  repro sentence. The custom corpus covers front matter, footnotes, org
  syntax in text, links, images, tables and lists. Their expected HTML is
  the cmark-gfm form. It was rendered with `tests/cmark/html.lua` (passes
  all spec examples) and checked case by case against the audit's pandoc
  reference. The exceptions were written by hand:
  - `front-matter.md`: the metadata block is consumed. Nothing of it
    renders in the body, which is what IM-32's target (`#+TITLE` and
    other keywords) exports to.
  - `footnotes.md`: cmark-gfm's footnote HTML.
  - `input-bytes-crlf-nul.md` `nul`: U+0000 becomes U+FFFD (CommonMark
    2.3).
  - `raw-html.md` `html_block_script` / `gfm_disallowed`: GFM's tagfilter
    applies.

## Emacs settings (organ side's export)

| Setting | Reason |
|---|---|
| `org-export-with-toc nil`, `org-export-with-section-numbers nil` | A Markdown document has no table of contents or section numbers. IM-17 (N/A, register export-29) rules that the importer adds no option for this, so the export side turns them off. |
| `org-export-headline-levels 8` | Headings below level 3 stay headings instead of becoming lists (IM-17, same ruling). |
| `org-html-toplevel-hlevel 1` | A top-level org headline exports as `<h1>`, like a Markdown `#`. The default (2) shifts every heading by one, which is the backend's offset and not the import's meaning. Relative levels are not normalized; see TRIAGE.md. |
| `org-html-checkbox-type 'html` | ox-html's own `<input type="checkbox">` rendering of a checkbox, the element GFM task lists use. The default `<code>[X]</code>` shows the same state. |
| `org-html-htmlize-output-type nil` | No fontification spans in code blocks, whether or not htmlize is on the load path. The output under `-Q` is the same; the setting fixes it. |
| `org-export-use-babel nil` | The corpus holds inline source calls (`src_python{1+1}`). Running corpus code is not part of what an import means, and the gate must not run it. Babel at export is ruled separately (R8). |
| `(conformance-clock-pin)` | Shared pinned clock. |

Everything that carries import meaning stays at its default:
sub/superscripts, special strings, entities, LaTeX fragments, and the
abort on a broken link. These defaults are what IM-14, IM-15, IM-16 and
IM-19 observe.

## Normalization (`normalize.lua`, both sides alike)

Each example's HTML is parsed into an element tree and written back in one
canonical form: block elements open and close on their own lines; a run of
inline content is one line. A `=== <label> ===` line separates the
examples. An `ORGAN-ERROR:` or `EMACS-ERROR:` line passes through as is.
Each rule and the reason it does not change meaning:

1. Character references (numeric, and the named ones in `ENTITIES`) are
   decoded, and text is re-escaped for `&`, `<` and `>` only. A reference
   and its character are the same text. Unknown names stay literal, so
   they can only add a difference, never hide one. U+00A0 and U+200B
   are written as `&#xa0;` / `&#x200b;` so they stay visible; they are
   not folded into spaces.
2. Whitespace. Outside `pre`, `script`, `style` and `textarea`, a run of
   ASCII whitespace becomes one space. It is trimmed at line ends and next
   to block-level tags, including across inline element boundaries. HTML
   renders all of these the same. Inside those elements the content is
   kept byte for byte (blank lines included), with two exceptions. A
   newline right after `<pre>` is dropped, as the HTML parser drops it.
   One final newline is dropped, because it renders no line.
3. Containers ox-html adds are unwrapped and their content kept: section
   divs (`outline-N`, `outline-text-N`), `org-src-container` and the
   `figure` div around a standalone image. `colgroup`/`col` are dropped,
   because each cell carries its own alignment.
4. Ids Emacs generates (`org` + 7 hex digits) are dropped. CommonMark HTML
   has no ids, so there is nothing to map them to. A fragment link to such
   an id is rewritten to name the element it points to (`#[tag text]`), so
   a link to a wrong element still differs. Other ids (CUSTOM_ID, user
   HTML) compare literally.
5. Class tokens ox-html generates are dropped: `org-*`, `outline-*`,
   `foot*`, `figure`, `src`, `src-*`, `example`, `on`/`off`/`trans`, and
   the spec's `language-*` after rule 6 reads it. Other classes compare
   literally.
6. Code blocks. `<pre><code class="language-X">` and ox-html's
   `<pre class="src src-X"><code>` both become `<pre lang="X">`.
   `src-nil` stays `lang="nil"`: a block that names a language called
   `nil` is not a block with no language (IM-6). An example block has no
   language.
7. `b` and `i` become `strong` and `em`. They are ox-html's markup for org
   bold and italic, the constructs organ maps Markdown strong and emphasis
   to.
8. Ordered lists. Each `li` gets the ordinal it renders with (`n`),
   computed from `ol start` and `li value` as HTML numbers lists, and
   `start`/`value` are dropped. `<ol start="5">` and a first
   `<li value="5">` then compare equal, and wrong numbering still differs.
9. Table cells. Alignment from `align`, `style="text-align:..."` or the
   `org-left/center/right` class becomes `align="..."`. A cell with no
   alignment has none, and `left` is not folded into "none". `scope` and
   the table's presentation attributes (`border`, `cellspacing`,
   `cellpadding`, `rules`, `frame`) are dropped. A cell whose only content
   is one U+00A0 counts as empty, because ox-html fills empty cells with it.
10. Checkbox inputs drop `disabled`; GFM marks rendered task boxes
    read-only and ox-html's box is outside any form. Boolean attributes
    compare by presence (`checked=""` = `checked='checked'`).
11. Footnotes. Both cmark-gfm's form (`sup.footnote-ref` /
    `section.footnotes` > `ol` > `li`) and ox-html's (`sup` > `a.footref` /
    `div#footnotes` > `div.footdef`) become `<fnref n>` and
    `<footnotes><fn n>` with the definition's content. Back-references,
    ox-html's "Footnotes:" heading and the generated anchors are dropped.
    Numbers and content still compare. An org file with the faithful
    footnotes normalizes identically to `footnotes.md`'s reference
    (checked).
12. URLs (`href`, `src`). A percent-escape of a space, a non-ASCII byte or
    an unreserved character is decoded. RFC 3986 6.2.2.2 and WHATWG URL
    parsing make both spellings the same URL. Other escapes are kept,
    with uppercase hex.
13. `role` on links is dropped; ox-html adds ARIA roles to its footnote
    links.

## Kept on purpose

These are not normalized, and each one shows up as a signature or a
TRIAGE.md entry:

- `<p>` inside `<li>` (tight versus loose lists).
- `left` versus no alignment.
- Absolute heading levels.
- `title` attributes (IM-25).
- `file://` on root-relative links (IM-21).
- `src-nil` (IM-6).
- U+00A0 versus a space.
- The `nil` text Emacs writes for an empty quote block.

U+200B stays visible too. The escaper planned for IM-7, IM-8, IM-10,
IM-13 and IM-14 inserts it, so every escaped example will show
`&#x200b;` against the reference. Whether to normalize it is decided with
that step's zero-width-space check (P4 gate).

Heading ids: if IM-20 is fixed by giving imported headlines a
`CUSTOM_ID`, every heading gains an `id` that the spec HTML lacks. That
step decides how such ids compare.
