# latex gate: Emacs settings, case modes and normalization

## Emacs settings (emacs.el)

| Setting | Reason |
|---|---|
| `(conformance-clock-pin)` | Pins "now" for `% Created`, `\today` and every other time read, as on the organ side. |
| `(require 'org-inlinetask)` | organ always recognises inline tasks (15 stars); `emacs -Q` does not load the library, which would read them as level-15 headlines. |
| `(random <case basename>)` before each export | ox-latex labels (`sec:org1a2b3c4`) come from `random`; seeding per case makes them stable across runs and independent of the rest of the corpus. |
| `user-full-name ""`, `user-mail-address ""` | ox-latex always writes `\author{<user-full-name>}`; the value is the host's login name. organ has no such default, so it is pinned empty. |
| `org-export-creator-string "Emacs (Org mode)"` | The default embeds the Emacs and org version numbers, which differ between hosts. |
| `org-resource-download-policy nil` | Keeps a batch export from prompting about remote resources. |
| `:eval never-export` in `org-babel-default-header-args` | Babel stays on at export (Emacs's default and organ's ruling R8), so `:exports none` and `:exports results` behave as in Emacs, but no code block is run by the gate. |

## Case modes

A case's first line may be an org comment `# conformance: BACKEND body|full`
(both exporters drop comment lines). Without it the case is exported by
`latex` body-only, the form most element cases need. `full` exports the
whole document (preamble, title block, `\end{document}`). `beamer` cases are
exported through organ's separate Beamer entry point
(`organ.export.beamer`) in the option run `beamer`, and through `ox-beamer`
on the Emacs side; in the other run both sides render them as an empty
output, and likewise for `latex` cases in the `beamer` run.

## Normalization (normalize.lua)

1. Generated labels are mapped by element. ox-latex names every
   referenceable element with a random `orgXXXXXXX` (`sec:` headlines,
   `fig:`, `tab:`, `eq:`, `lst:`, bare for targets, radio targets and
   footnotes), while organ uses CUSTOM_ID, NAME or a title slug (LX-4,
   LX-43; ruled KEEP, and R4 adds no option because Emacs's form is
   random). The Emacs side's n-th generated label of a family is renamed to
   organ's n-th label of the same family, in order of definition
   (`\label{..}`, `label={..}`, `label=..`), and every reference
   (`\ref`, `\hyperref[..]`) is rewritten through the same map, so a
   reference that points at a different element on the two sides still
   differs. Labels are never collapsed to a shared token. A generated label
   organ has no partner for (organ emits no label: LX-22, LX-29 radio
   targets, LX-36 frames) is left as Emacs wrote it, seeded and stable.
   User labels (CUSTOM_ID, NAME, targets, `BEAMER_opt label=`) are never
   rewritten.
2. A run of blank lines becomes one blank line on both sides. TeX reads
   any run of blank lines as a single paragraph break. Single blank lines
   are kept, so a missing or extra paragraph break is a difference.
   Inside `verbatim`, `Verbatim`, `lstlisting` and `minted`, where every
   line prints, lines compare literally (this rule and rule 3).
3. Spaces before a line-final `\\` are dropped on both sides, unless the
   character before them is a backslash (a control space). LaTeX's `\\`
   starts with `\unskip` in paragraphs and table cells, so `x \\` and
   `x\\` typeset the same.
4. organ's Beamer `\frame{\titlepage}` line reads as `\maketitle`. Inside a
   Beamer document outside a frame both produce the title frame; the
   inventory rules this form equivalent (LX-38, R3).

Nothing else is normalized: the `% Created` line, preamble order, escapes,
whitespace and the pinned date compare literally.
