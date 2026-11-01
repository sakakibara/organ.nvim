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
| `tz` | Optional: the TZ setting the case runs under. Without it the case runs under `TZ=UTC` with the rest of the corpus. |

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
  not print (a function, a subr, a string with text properties, a NaN,
  whose sign and payload organ does not keep). organ
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
  changes the shape of Emacs's time values, so the current time is tested
  for shape only.
- Cases with a `tz` header run apart, one pair of processes per zone:
  `gate.lua` starts `zone.lua` with `TZ` set to the zone, and that run's
  Emacs and organ both read it, as the C library reads `TZ` once per
  process. Each side checks that `TZ` matches the case's zone (`UTC` for
  the rest), and each run takes the signature rows of its own cases.
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
outside the subset (`function`), a builtin outside
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
of strings built separately (`eq-identity`). Time adds `locale` for what Emacs takes from the C
library's locale or where glibc and macOS's C library disagree: day and
month names, AM/PM and the locale's date and time formats
(`%a %A %b %B %h %c %x %X %p %P %r` and the `E` forms that reach the
C library), the abbreviation of the UTC zone (`GMT` on glibc), a
non-ASCII format string, a zone setting that is neither a zoneinfo file
nor a POSIX string with explicit rules (or one whose names or offsets
one of them rejects), a POSIX rule before 1970 (or before its first
change in 1970, south of the equator) or after 2569, a local
time in a daylight saving overlap without a DST flag, or in a gap or
overlap whose sides share their flag (gnulib's mktime answers from its
last call), a
DST flag no time within a year has (glibc moves the time an hour back),
and times within days of the end of the representable range; `precision`
for a space-padded signed number wider than its width (Emacs aborts);
`eq-identity` for a time comparison or `time-subtract` of two boxes that
could be one object; and `free-variable` for the custom formats
`org-time-stamp-format` reads when CUSTOM is non-nil. Lists and
sequences add:
`nconc` that would make a list reach itself through its cdrs or its
elements (organ keeps lists and vectors acyclic), `mapconcat` over a
list its function shortens (Emacs reads results it never stored and
aborts) (`cycle`); `memq`, `memql`, `assq`, `rassq`, `delq` and `remq` comparing two boxes
that could be one object, and `equal` too deep to answer in the hash
table of `delete-dups` or `seq-uniq` on a list longer than 100, where
Emacs compares only on a hash collision and symbols hash by address
(`eq-identity`); a NaN that `value<` compares or that such a hash table
holds (`nan`); and `value<` of a closure, or the elements of a closure
that `append`, `vconcat` or `aref` would read (`unprintable`). Calendar
and diary functions add: in the `prefix` profile, which has diary-lib only
when something else loaded it, `org-date`, `org-block`, `org-cyclic` and
`org-anniversary`, which call into it, and `org-class` with weeks to skip,
which checks holidays (`profile`); and in the `diary` profile, `org-class`
skipping holidays or a named holiday, or skipping weeks on a date that is
not valid or lies after 9999, where the user's holiday list decides or
Emacs's holiday forms may never finish, when the caller supplies no
`calendar-check-holidays` (`holidays`). The gate fails on any row that
records `REFUSED internal`.

`XT-10` (KEEP) rows record the one other kind of difference: a `diary`
sexp that is a single call of `diary-date`, `diary-anniversary`,
`diary-cyclic` or `diary-block` with literal arguments (numbers, and `t`
for `diary-date`) reads a date triple
year-first when its first value is a number above 31, or `t` while its
last is neither `t` nor a number above 31, where Emacs reads it in
`calendar-date-style` order.

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
form, macro and builtin is called with every argument count up to eight,
directly and through `funcall`, and generation fails unless the counts Emacs
accepts form one range; the data head of each refused count is recorded,
the highest count's as the default and the counts whose head differs (the
generic `seq-*` functions with no argument) on their own. It
also checks the case facts organ relies on: `upcase-initials` agrees with
`capitalize` on characters and one-character strings, the case-fold
canonical form is `downcase` of `upcase` of `downcase`, and no non-ASCII
character folds to an ASCII one.

## Builtin coverage

`organ.lua` wraps every builtin of the subset and records the ones a Lisp
form calls (a call one builtin makes inside another is not counted). After
the data check the gate fails on any builtin of the subset that no case
calls, counting the cases of every zone's run.

## Fuzz

Last, `fuzz.lua` generates forms from five fixed seeds: 2000 forms per seed
and profile, in files of 100 under a header with a random `case_fold` (and,
for `diary` and `prefix`, a `date` and an `entry`). Every form is valid for
its profile and calls only builtins of the subset, with nesting depth up to
5, literal lists, vectors and strings up to 64 elements, `format` widths up
to 40 and integers up to a few hundred digits. The generator calls every
builtin of the subset (the gate fails otherwise) and leaves out what makes
Emacs abort or never finish: `format-time-string` space padding (`%_`),
`%.0c` with a width, holiday checks of `org-class` on a date before year 1
or after 9999, and lists `nconc` or `mapcan` would splice into a cycle
that later builtins walk; a cycle is made only by a form whose result is
the cyclic list. Sizes
Emacs would allocate or loop over (`make-string` counts, `dotimes` counts,
`expt` exponents) stay small, and the elements mapped over by nested
mapping functions stay below a fixed amount of work, so no form reaches a
cap.

Emacs evaluates the files as it does the cases (one process per profile,
`TZ=UTC`). A `diary` form that is a top-level call XT-10 rewrites is
followed in the Emacs file by the call with the year-first triples moved to
`calendar-date-style` order. Each form's organ line must equal Emacs's,
except:

- the form is rewritten by XT-10 and organ's line equals Emacs's line for
  the reordered call (counted as XT-10);
- organ refuses, and the refusal's precondition holds on organ's trace of
  the evaluation: the builtin calls active when the refusal was raised,
  with their arguments. `nan`: a NaN among the innermost call's arguments
  or returned by a builtin it called (or in the printed value). `width`: a
  control character, TAB, a
  character a CJK language environment widens or one an automatic
  composition may join, in a string, symbol name or character among them,
  or a string with text properties among them.
  `regexp`: a regexp argument of `split-string` or `string-trim*` holding a
  regexp special character, or a non-ASCII cased letter under case
  folding. `case-special`: a capital sigma in the argument of `downcase`,
  `capitalize` or `upcase-initials`. `locale`: per detail, a quote in an
  `error` or `user-error` format, a numeric directive given a non-number,
  a non-string `truncate-string-to-width` ellipsis, a locale directive,
  `%Z`, or non-ASCII text in a `format-time-string` format, a fixed zone
  offset of 25 hours or more or a zone name of other characters, a DST flag
  given to `encode-time`, a time of 2^30 or more, or a zone setting (a
  string or `wall`). `eq-identity`: two distinct strings, floats, vectors or
  bignums (conses too, for the time functions) with equal contents.
  `cycle`: `nconc` arguments sharing a cons or vector, or a list
  `mapconcat` maps that shortened while mapping. `holidays`: `org-class`
  with weeks to skip holding `holidays` or a string, or on a `date` that is
  not valid or lies after 9999. `profile`: a `prefix` call of `org-date`,
  `org-block`, `org-cyclic`, `org-anniversary`, or of `org-class` with
  weeks to skip. `precision`: a `format` directive with a precision above
  99, `%e %f %g` of an integer in [-2^63, 2^64) that is not a double, a
  negative `%b` with a precision, or `%.0c` of a sign character with a
  width. `unprintable`: a function or a string with text properties.
  `charset`: an integer above `#x10FFFF` or a surrogate. `function`: an
  argument naming a symbol outside the subset. `free-variable`:
  `org-time-stamp-format` with CUSTOM non-nil. Any other refusal, and any
  limit, is a disagreement.

The gate fails on every disagreement. With `ORGAN_ELISP_FUZZ_STATS` set it
prints the forms, agreements, refusals by code, XT-10 rewrites and
disagreements per seed and profile.
