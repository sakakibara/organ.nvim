# elisp gate: case format, output shape and Emacs settings

The gate reads or evaluates each case's Lisp forms through Emacs
(`emacs.el`) and through `organ.elisp` (`organ.lua`) and diffs the two
texts per case. Run it with
`TZ=UTC LC_ALL=C nvim --headless -l tests/conformance/elisp/gate.lua`.

No normalize.lua: both sides print the same shape directly.

## Case format

A case is one file in `cases/` made of blocks separated by empty lines.
The first block is the header: lines starting with `;`, of which
`; KEY: VALUE` lines configure the run and the rest describe the case.

| Key | Meaning |
|-----|---------|
| `profile` | The consumer whose Emacs entry point the case follows: `table`, `diary`, `prefix`, `capture`, `var` or `link`. |
| `mode` | `read`: read each item and print it, without evaluation. `eval`: read each item and evaluate it as the profile's Emacs entry point does. |
| `case_fold` | `eval` mode: `t` or `nil`, the `case-fold-search` the evaluation sees (organ's `ctx.case_fold`). |
| `date` | `eval` mode, optional: a Lisp form, read, bound dynamically as `date` (organ's `ctx.variables.date`). |
| `entry` | `eval` mode, optional: the rest of the line, as a string bound dynamically as `entry`. |

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
  prints the same for a signal.
- `!! SYMBOL <unprintable>`: the signal's data holds a value organ does
  not print (a function, a subr, a string with text properties). organ
  prints this when its result has no text; Emacs prints it when it finds
  such a value in the data, so the two sides agree on which data is
  unprintable rather than organ assuming it.
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
- `eval` mode evaluates each item with `(eval FORM LEXICAL)`, LEXICAL nil
  for the `table`, `diary` and `link` profiles and t for `prefix`,
  `capture` and `var`, with `case-fold-search` bound to the header's
  `case_fold` and the header's `date` and `entry` bound dynamically.
  `print-escape-newlines` is t only while the result is printed, so a
  value printed during evaluation (`%S` in an error message) sees nil, as
  in the consumers. An item that sets a global variable comes last in its
  case, since Emacs keeps the setting for later items.

## Expected differences

Each signature row is `R6-OUT` (KEEP): organ refuses an input Emacs reads
or evaluates. The refused syntax is the read syntax outside the subset
(`#s(`, `#&`, `#@`, `#$`, `#N=` and `#N#`, `#(`, `#[`, `#^[`, `#^^[`,
`#!`, `##`, `#:`, `#_`, `#<`), named characters `\N{NAME}`, character
modifiers other than a control character on ASCII, strings that would be
unibyte, and NaN in printing. In `eval` mode the refusals are: a function
outside the subset or not yet implemented (`function`), a builtin outside
its profile (`profile`), a variable bound by neither the form nor the
caller (`free-variable`), a `setq` of one (`setq-global`), a binding of a
special variable other than `case-fold-search` and `calendar-date-style`
(`special`), an `error` or `user-error` format string with a quote
(`locale`: `text-quoting-style`), a dotted condition list (`syntax`;
Emacs 31 aborts on one that matches), and malformed forms in the body of a closure created
where a variable is bound lexically (`syntax`), where Emacs's
macroexpand-all and closure conversion rewrite or reject them. Numbers
and equality add: `eq` or `eql` of two distinct strings, floats, vectors
or integers beyond `most-positive-fixnum` that could be one object in
Emacs (`eq-identity`), a NaN printed or compared by contents (`nan`),
`equal` of two distinct closures (`unprintable`), and `functionp` of a
symbol organ does not know (`function`) or of a diary function outside
the profiles that define it (`profile`). Strings add: a regexp argument
other than the default or a literal string, or a literal holding a
non-ASCII cased letter under case folding (`regexp`); a width measured
over a character whose width differs between users (a control character
or TAB, a character a CJK language environment widens, a character an
automatic composition may join in `string-width`) or over a string with
text properties (`width`); lowercasing a capital sigma inside a word
(`case-special`); `format` precision above 99, an integer `%e %f %g`
would print as a long double, a negative `%b` with a precision and
`%.0c` of a sign character with a width (`precision`); a NaN printed
with a sign (`nan`); a character outside Unicode scalar values in a
string (`charset`); `truncate-string-to-width` with a non-string
ELLIPSIS and Emacs's "Format specifier doesn't match argument type"
message (`locale`); the `length` of a closure (`unprintable`); and `eq`
of strings built separately (`eq-identity`). The gate fails on any row
that records `REFUSED internal`.

## Data check

After the corpus, the gate regenerates `lua/organ/elisp/data/` with
`scripts/elisp-data.el` into a temporary directory and fails on any
difference, then has Emacs dump every code point's syntax under the org and
elisp syntax tables and runs organ's `syntax.lookup` over the dump. A second
dump gives every character's `upcase`, `downcase` and `capitalize` (of the
character up to `#x3FFFFF`, and of its one-character string), its case-fold
canonical form, its `char-width` in an org-mode buffer, whether
`composition-function-table` holds a rule for it and whether a CJK
language environment changes its width; the gate runs `organ.elisp.chars`
over it. The generator itself checks the call data it writes: each special
form, macro and builtin is called with every argument count up to seven,
directly and through `funcall`, and generation fails unless the counts Emacs
accepts form one range; the data head of each refused count is recorded,
the highest count's as the default and the counts whose head differs (the
generic `seq-*` functions with no argument) on their own. It
also checks the case facts organ relies on: `upcase-initials` agrees with
`capitalize` on characters and one-character strings, the case-fold
canonical form is `downcase` of `upcase` of `downcase`, and no non-ASCII
character folds to an ASCII one.
