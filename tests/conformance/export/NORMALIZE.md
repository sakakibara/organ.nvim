# export gate: Emacs settings, case modes and normalization

The gate covers organ's ASCII, Markdown, Texinfo, iCalendar and OPML
exporters and the org->org serializer (`to_org`).

## Case modes

Every case starts with an org comment `# conformance: BACKEND full`, the
latex gate's convention (both sides drop the comment, except the org->org
round trip, where both sides keep it). The backend picks the exporter on
each side:

| BACKEND | Emacs side | organ side |
|---|---|---|
| `ascii` | `(org-export-as 'ascii)` | `organ.export.ascii` |
| `md` | `(org-export-as 'md)` | `organ.export.markdown` |
| `texinfo` | `(org-export-as 'texinfo)` | `organ.export.texinfo` |
| `icalendar` | `org-icalendar-export-to-ics` on a copy of the case in a scratch directory; the gate reads the written file | `organ.export.ics` |
| `icalendar-combine` | `org-icalendar-combine-agenda-files` with `org-agenda-files` = the case and the combined file in a scratch location | the case is indexed, then `ics.export_query` (`:Org export ics_all`) |
| `org` | `org-element-interpret-data` of `org-element-parse-buffer` (not ox-org) | `to_org.render(from_org.from_lines(...))` |
| `opml` | `expected/<case>.out` (see OPML below) | `organ.export.opml` |

Every case exports the whole document (`full`), as the ledger's runs did.
iCalendar uses the real file export rather than `org-export-as`, so the
CRLF line ends a user's `.ics` gets are compared.

### OPML has no Emacs oracle

Emacs ships no OPML exporter (`ox-opml` is third-party and absent here), so
the Emacs side of an `opml` case returns a hand-written expected output,
`expected/<case>.out`. It is organ's current output with only the changes
the ledger entry for OPML states, against OPML 2.0 (opml.org/spec2.opml):

- `_note` holds the whole first body paragraph. Its line breaks are soft
  (org fills paragraphs), and XML attribute-value normalization reads a
  raw newline as a space, so the lines join with one space, as organ's
  `escape_attr` already does.
- `<title>` is the title as plain text (markup stripped, entities
  escaped), and absent when `#+OPTIONS: title:nil`.
- The optional head elements are filled: `dateCreated` from `#+DATE` in
  RFC 822 form (`Fri, 02 Jan 2026 00:00:00 GMT`, OPML 2.0 requires RFC
  822 dates), `ownerName` from `#+AUTHOR` (`author:` on by default),
  `ownerEmail` from `#+EMAIL` only with `email:t` (off by default, as in
  every org backend), in the order the spec lists them.

The expected files are not in `manifest.tsv` (every manifest row is a
case the runner exports); change them only together with a ruling on the
OPML entry.

## Emacs settings (emacs.el)

| Setting | Reason |
|---|---|
| `(conformance-clock-pin)` | Pins "now" for `DTSTAMP` and every other time read, as on the organ side. |
| `(require 'org-inlinetask)` | organ always recognises inline tasks (15 stars); `emacs -Q` does not load the library and would read them as level-15 headlines. |
| `(random <case basename>)` before each export | ox-md anchors (`orgXXXXXXX`) come from `random`; seeding per case makes them stable and independent of the rest of the corpus. |
| `user-full-name ""`, `user-mail-address ""` | Every backend defaults the author to the host's login name. organ has no such default (OX-2, an option row in index.tsv), so it is pinned empty. |
| `org-export-creator-string "Emacs (Org mode)"` | The default embeds the Emacs and org version numbers, which differ between hosts (printed by `creator:t`). |
| `org-export-with-broken-links t` | Several cases hold links with no target (the ledger's corpus, run with this setting). Without it Emacs aborts the export; organ never aborts on a broken link (decision register export-15). |
| `org-id-locations-file` in a temp file | Resolving `id:` links must not read or write `~/.emacs.d/.org-id-locations`. |
| `org-resource-download-policy nil` | Keeps a batch export from prompting about remote resources. |
| `:eval never-export` in `org-babel-default-header-args`, `-inline-header-args` and `-lob-header-args` | Babel stays on at export, so `:exports` behaves as in Emacs, but no code block, inline block or call is run by the gate (without the inline and lob settings Emacs prompts on stdin). Export-time evaluation itself (OX-34) has a `unit` row in index.tsv. |

## Normalization (normalize.lua)

1. iCalendar: CRLF line ends read as plain lines on both sides. RFC 5545
   3.1 requires CRLF and both sides write it; a line ended by a bare LF
   keeps a visible `<bare-LF>` mark after a blank, so a side that stopped writing CRLF
   still differs.
2. iCalendar: Emacs's generated UIDs are mapped by entry. Without an
   `:ID:` property ox-icalendar makes a random UUID per entry (prefixed
   `TS1-`, `SC-`, `DL-`, ... per component) and a random decimal UID for a
   diary entry; these change on every run. Each distinct value is renamed
   `<uuid-N>` in order of first appearance, and every occurrence of the
   same value gets the same name, so two components of one entry still
   share a UID and components of different entries never do. UIDs from
   `:ID:` properties and every organ UID compare literally (OX-70 holds
   the scheme difference).
3. `icalendar-combine` only: folded lines are unfolded on both sides (RFC
   5545 3.1: a CRLF followed by a space is removed when reading), and the
   case's absolute path reads as `<case>`. organ's `ics_all` UIDs embed the
   file's absolute path (OX-70), which differs per checkout, and its fold
   points move with the path length. This case holds only ASCII, so
   unfolding hides no multi-octet split; folding is compared in every
   other iCalendar case (OX-77).
4. Texinfo:
   - a run of blank lines becomes one blank line on both sides; TeX and
     makeinfo read any run of blank lines as one paragraph break, and
     single blank lines are kept; inside `@example`, `@verbatim`,
     `@lisp`, `@display`, `@format` and their `small` forms, where blank
     lines print, they compare literally;
   - the `@c` comment after `\input texinfo` on the first line is
     dropped (a comment: `@c -*- texinfo -*-` and `@c -*-texinfo-*-` are
     editor mode lines);
   - inside `@itemize` and `@enumerate`, a line that is only `@item`
     joins the line after it: Texinfo reads the text after `@item` on the
     same line or on the next line as the start of the same item. This is
     not applied in `@table`, `@vtable`, `@ftable` or `@multitable`, where
     the rest of the `@item` line is the item's term or first cell.
5. Markdown:
   - trailing blank lines at the end of the document are dropped
     (CommonMark ignores them); blank lines elsewhere compare literally,
     because the ruling on OX-49 fixes heading spacing;
   - a block-quote line of `>` and a blank reads as `>` (CommonMark 5.1: the space after
     `>` is optional and consumed);
   - HTML character references read as the characters they name, named
     (from organ's WHATWG table) and numeric alike, except the five
     markup characters (`&amp;` `&lt;` `&gt;` `&quot;` `&apos;` and their
     numeric forms), whose escaped and raw forms differ in Markdown.
     CommonMark decodes `&ndash;`, `&#x2013;` and a literal U+2013 to the
     same text; inventory R3 names character references (HX-59) among the
     spellings that need not match byte for byte. References in fenced
     code, in lines indented four spaces or a tab (code blocks, and list
     continuations, which then compare literally), and in code spans
     compare literally, as CommonMark shows them there.
6. Bytes that are not valid UTF-8 read as `<0xHH>` on both sides, so a
   split multi-octet character (OX-77) shows in the diff while the
   signature file stays valid UTF-8. No valid text is changed.
7. ASCII: tabs expand to spaces at 8-column stops on both sides. ox-ascii
   centres and right-justifies lines with `indent-tabs-mode` on, so it
   writes tabs where organ writes spaces; at the 8-column tab stops plain
   text assumes, they print identically.

Nothing else is normalized: blank lines in ASCII and Markdown, the pinned
`DTSTAMP`, `PRODID`, anchors (seeded), headers and escapes compare
literally. Generated Markdown anchors are left as Emacs wrote them
(seeded, stable); they differ from organ's slugs under OX-48 (KEEP, no
option per R4).
