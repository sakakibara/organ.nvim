# duration gate: case format, output shape and range

The gate runs each item through Org's `org-duration.el` (`emacs.el`) and
through `organ.duration` (`organ.lua`) and diffs the two texts per case,
then does the same for the fuzz (`fuzz.lua`), which must find no
disagreement. Run it with
`TZ=UTC LC_ALL=C nvim --headless -l tests/conformance/duration/gate.lua`.

No normalize.lua: both sides print the same shape directly.

## Case format

Each line of a case is one item, except blank lines and lines starting
with `;`. An item is a Lisp form whose arguments are data, read and never
evaluated:

| Item | Call |
|------|------|
| `(p S)` | `org-duration-p` |
| `(to-minutes D [CANONICAL])` | `org-duration-to-minutes` |
| `(from-minutes M [FMT [CANONICAL]])` | `org-duration-from-minutes` |
| `(h-mm-only-p (S...))` | `org-duration-h:mm-only-p` |

organ reads the item with `organ.elisp`'s reader and turns `FMT` into
the format encoding `organ.duration` documents. An integer `M` and the
float of the same value are separate items: Emacs formats the two apart
only outside the range below, and organ, which sees one Lua number, must
match both inside it.

## Output shape

One line per item:

- `=> PRINTED`: the value, printed with `prin1` under
  `print-escape-newlines` t (`org-duration-p` as `t` or `nil`).
- `!! "MESSAGE"`: Emacs signalled; the `error-message-string`, printed
  the same way. organ prints its error message.
- `!! out of range`: the item crosses the range condition. Emacs decides
  this before calling org-duration, in exact integer arithmetic; organ
  prints it when it refuses with `duration out of range`.

## Range

`to-minutes` crosses when the computation, followed in Emacs's order up
to where it would signal, forms an integer of 2^53 or more: a parsed
integer, a product of an integer with an integer modifier, 60 times the
hours, or a running integer sum. `from-minutes` crosses when
`|M| * 60 >= 2^53`.

## Fuzz

Five fixed seeds. Each generates duration strings from a grammar (digit
runs, long ones included, dots, colons, units in mixed case, blanks, tabs
and noise characters, then token mutations), each called as `p` and as
`to-minutes` without and with CANONICAL; minutes (integers, floats,
negatives, values near and past the bound, infinities and a NaN) times
the fixed formats and random ones; and `h-mm-only-p` lists. Sizes are
fixed in `fuzz.lua`.

## Emacs settings

`emacs -Q --batch`, `case-fold-search` at its default `t`, every Org
option at its default.
