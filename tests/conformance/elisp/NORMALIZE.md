# elisp gate: case format, output shape and Emacs settings

The gate reads (and, in later parts, evaluates) each case's Lisp forms
through Emacs (`emacs.el`) and through `organ.elisp` (`organ.lua`) and diffs
the two texts per case. Run it with
`TZ=UTC LC_ALL=C nvim --headless -l tests/conformance/elisp/gate.lua`.

No normalize.lua: both sides print the same shape directly.

## Case format

A case is one file in `cases/` made of blocks separated by empty lines.
The first block is the header: lines starting with `;`, of which
`; KEY: VALUE` lines configure the run and the rest describe the case.

| Key | Meaning |
|-----|---------|
| `profile` | The consumer whose Emacs entry point the case follows: `table`, `diary`, `prefix`, `capture`, `var` or `link`. |
| `mode` | `read`: read each item and print it, without evaluation. |

Every further block is one item: its lines, joined with newlines, are the
source string. Leading lines of the form `; naive: LINE` are not part of
the source; they record the answer a naive implementation would give for
an item that targets an Emacs-specific rule, and the gate fails when
Emacs's line equals it, so the item keeps testing what it claims to.

## Output shape

One line per item:

- `=> PRINTED`: the item read without error and printed with `prin1`
  under `print-escape-newlines` t.
- `!! TEXT`: Emacs signalled, and `TEXT` is `(format "%s" err)`. organ
  prints the same for a signal; when the signal's data holds a value organ
  does not print, it prints `!! SYMBOL <unprintable>` instead.
- `REFUSED CODE DETAIL` / `LIMIT CAP` (organ only): the input is outside
  the subset, or a cap stopped it.

A newline inside `TEXT` or `DETAIL` prints as `\n`, so each item stays one
line. A newline in a printed symbol name stays raw, as `prin1` prints it,
on both sides.

## Emacs settings

- One Emacs process per profile: `conformance-run` starts a child per
  profile, which loads that profile's features (`org`, plus `org-agenda`,
  `diary-lib`, `calendar`, `org-capture`, `ob-core` or `ol`), so a feature
  one profile loads never reaches another.
- Items are read with `read-from-string` from the case file decoded as
  UTF-8, inside an `org-mode` temporary buffer, never through `--eval`.
  Reading from a string gives `invalid-read-syntax` data without the line
  and column a buffer source adds, as consumers read strings too.
- `_collate.el` is loaded, as on every gate. `_clock.el` is not: its pin
  changes the shape of Emacs's time values.

## Expected differences

Each signature row is `R6-OUT` (KEEP): organ refuses an input Emacs reads.
The refused syntax is the read syntax outside the subset (`#s(`, `#&`,
`#@`, `#$`, `#N=` and `#N#`, `#(`, `#[`, `#^[`, `#^^[`, `#!`, `##`, `#:`,
`#_`, `#<`), named characters `\N{NAME}`, character modifiers other than
a control character on ASCII, strings that would be unibyte, and NaN in
printing. The gate fails on any row that records `REFUSED internal`.

## Data check

After the corpus, the gate regenerates `lua/organ/elisp/data/` with
`scripts/elisp-data.el` into a temporary directory and fails on any
difference, then has Emacs dump every code point's syntax under the org and
elisp syntax tables and runs organ's `syntax.lookup` over the dump.
