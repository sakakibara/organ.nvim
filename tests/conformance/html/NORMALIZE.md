# html gate: Emacs settings and normalization

Both sides export a full document: Emacs with `(org-export-as 'html)` on
the visited case, organ with `require("organ.export.html").export` and
only `file_path`, as `:Org export html` calls it.  The comparison is
semantic (inventory policy R3): two documents a browser treats the same
must normalize to the same text, and every difference in structure,
classes, ids or content must survive.

## Emacs settings (emacs.el)

| Setting | Reason |
|---|---|
| `(conformance-clock-pin)` | Both sides see 2026-05-04 09:30 UTC; the `<!-- date -->` comment and the postamble's `Created:` compare literally. |
| `HOME=/home/conformance` | `file:~/x` links expand `~`; a fixed home keeps the output independent of the machine. |
| `vc-handled-backends nil` | Visiting a case inside the git checkout otherwise starts version-control probes that add about 0.4 s per case; no export output depends on them. |
| `user-full-name ""`, `user-mail-address ""` | Emacs's default author and email come from the machine's user; organ has no such default. Cases that want an author set `#+AUTHOR`. |
| `org-export-creator-string "Emacs (Org mode)"` | The default embeds the Emacs and Org version numbers, so `creator:t` output would change with the installed Emacs. |
| `org-export-with-broken-links 'mark` | Emacs's default aborts the whole export at the first broken link, which would hide every other difference of the cases that hold one. Ruling R9 / HX-45: organ never aborts; `mark` is the Emacs mode that still shows the link. Cases with an explicit `broken-links:` option override it, as in Emacs. The ledger was produced with the same setting. |
| `org-html-prefer-user-labels t` | Emacs then uses the user's own `CUSTOM_ID`, `#+NAME` and `<<target>>` names as anchors, so those user identifiers compare literally against organ's (HX-5 rules organ's readable anchor scheme). Elements without a user label still get generated ids, mapped below. |
| `org-todo-keywords` = organ's default sequence (`TODO NEXT WAITING HOLD PROJ \| DONE CANCELLED`) | Same keywords as organ's configuration and the parser gate's Emacs dump; in-file `#+TODO` lines still win on both sides. |
| `(require 'org-inlinetask)` | organ always parses inline tasks; Emacs only with this library loaded. |
| babel `:eval never-export` | Ruling R8: headless organ exports without evaluating (no export trust), so stored results are compared and no code runs. |

## Fixtures

`inc_code.txt`, `refs.bib` and `setup.inc` are read by other cases
(`#+INCLUDE`, `#+bibliography`, `#+SETUPFILE`).  The runner treats every
file under `cases/` as a case, so both sides render a non-`.org` file as
the line `fixture: <basename>`.  `inc_target.org` and `other.org` are org
files and are compared like any case.

## Normalization (normalize.lua)

Applied to both sides unless stated.  Output that does not start with
`<` (an `EXPORT-ERROR:` or `ORGAN-ERROR:` line, a fixture line) passes
through unchanged.

1. **Case directory.** The absolute path of `cases/` becomes `CASES`.
   Emacs resolves `attachment:` links to an absolute `file://` URL; the
   checkout location is not part of the document.
2. **Generated ids (Emacs side).** Emacs ids matching `orgXXXXXXX` are
   random per export.  They are mapped by element: each element carrying
   an `id` gets a kind (tag name, any `h1`-`h6` as one heading kind, `a`
   without `href` and `span` as one anchor kind, plus the `class`
   value), and the n-th element of a kind in the Emacs document is paired
   with the n-th element of the same kind in organ's document.  Pairing
   by first-occurrence order is sound here because both exporters walk
   the same parse tree in document order; where organ drops or adds an
   element of a kind, the pairing shifts and the shift shows as a
   difference, which is what such a case must show.  The generated id is
   then replaced everywhere in the Emacs text (`id`, `href="#..."`,
   `outline-container-...`, `\label{...}`) by its mapped value, so
   references compare through the map.  The map is one-to-one: when the
   paired organ id is already taken (organ gives two headlines the same
   id, HX-6) the next one becomes `<id>--dup2`, so the duplicate shows.
   A generated id whose element has no organ counterpart and that nothing
   in the document refers to is dropped: a random anchor no link uses
   carries no meaning (R4 adds no option for random ids).  A referenced
   one becomes `emacs-id-<kind>-<n>`; a generated token on no element
   becomes `emacs-ref-<n>`, numbered by first occurrence.  Ids are never
   collapsed to one token.  User identifiers are not touched.
3. **Character references.** Named and numeric references are decoded
   (HTML5 named table, legacy names without `;` as the HTML parser reads
   them) and the text re-encoded canonically: `&amp;` `&lt;` `&gt;`
   (`&quot;` in attributes), every non-ASCII character as `&#xHEX;`.
   `&nbsp;`, `&#xa0;` and a literal U+00A0 are the same character to a
   browser (R3 names HX-59 character references explicitly); a different
   character still differs (HX-57).
4. **Tags.** One tag per line, tag and attribute names lowercased,
   attributes sorted by name, values double-quoted; a repeated attribute
   keeps its first value, as the HTML parser does (so HX-48's duplicate
   `alt` shows organ's first value).  Void elements lose the XHTML `/`.
   `type="text/css"` on `<style>` and `type="text/javascript"` on
   `<script>` are dropped: they are the HTML defaults.
5. **Text and whitespace.** Outside `<pre>`, runs of space, tab, CR, LF
   and FF become one space, and a space at the start or end of a rendered
   line is removed: one separated from a block-level boundary (or the
   document edge) only by inline start tags before it or inline end tags
   after it, and whitespace.  CSS collapses exactly these.  Spaces
   between inline content stay.  Each text node is one line.  Void inline
   elements (`img`, `input`) count as content, not as a boundary.
6. **Preformatted text.** Inside `<pre>`, text is kept verbatim and
   split at newlines, one line per source line, each prefixed with `|`.
   The newline right after `<pre>` is dropped (the HTML parser drops it)
   and so is one final newline before `</pre>` (it ends the last line and
   adds none).  Indentation, tabs and empty lines inside stay.
7. **Head order.** The children of `<head>` are sorted stably: metas
   (charset declarations, viewport, then by `name`), scripts, the title,
   then styles and stylesheet links.  Order among head metadata has no
   meaning; the stable sort keeps the relative order of scripts and of
   styles, whose order does matter.
8. **Style and script bodies.** The content of a `<style>` or `<script>`
   becomes one line `#raw sha256:<first 16 hex digits>`.  Any change to
   either side's CSS or script changes the hash, so the comparison stays
   exact while a hunk stays one line; read the raw output to see the
   text.
9. **Comments.** HTML comments are moved, in order, to the end of the
   output: their position carries no meaning, their text (the pinned
   export date) still compares.
10. **Empty paragraphs.** A `<p>` without attributes holding only
    whitespace is dropped.  It has no content, padding or border, so its
    margins collapse through and it renders nothing (Emacs leaves one
    where `<:active` removes an inactive timestamp, organ leaves none).

Not normalized: blank lines carry no meaning in this serialization (each
node is a line), and nothing that the pinned clock fixes is masked.

## Signature conventions

`signatures.tsv` rows name every inventory entry whose difference is in
the hunk.  A hunk that mixes the KEEP part of an entry (HX-1, HX-5,
HX-11, HX-65, HX-79) with a FIX entry cannot be one row of one class: the
row is TRANSITIONAL with the FIX entries, and a `# keeps:` comment before
it names the KEEP entries.  When those fixes land the hunk shrinks to the
KEEP part and gets a KEEP row.  A hunk holding only a broken link, in a
case without a `broken-links:` option, is KEEP for HX-45 (Emacs would
abort; organ's own default rendering is its choice); in the option cases
it is TRANSITIONAL.

## Corpus

The cases are the auditor's corpus (`html/c/` beside the ledger), renamed
by content: `optN` -> `opt-<option>` (from `optmap.txt`, e.g. `opt9` ->
`opt-tags-not-in-toc`), `optbase` -> `opt-base`, `optlate` ->
`opt-late-keywords`, `o2_*` -> `small-*` (`o2_base` -> `small-base`,
`o3_colon` -> `small-fixed-width-nil`, `o3_bar` -> `small-tables-nil`,
`o2__nil_` -> `small-bare-colon-nil`, `o2___nil_` ->
`small-timestamps-nil`, `o2___0_` -> `small-h-0`), `t_tasks_*` ->
`tasks-*`, other underscores -> hyphens.  `o3_lt.org` was a byte copy of
`o2___nil_.org` and is not repeated.  `entities.org` is new: it holds
HX-57's ledger repro (the entity names whose characters differ, the
names only one side knows, and `\LaTeX{}`).
