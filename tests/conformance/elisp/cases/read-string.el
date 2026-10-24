; profile: table
; mode: read
; Strings: escapes, Unicode escapes, refused unibyte forms, printing.

"abc"

""

"a\nb"

"\t\r\f\e\a\d\s\v\b"

"\\ \""

"a\
b"

"a\ b"

"a
b"

"\101\0\7"

"\x41"

; naive: => "A 1"
"\x41\ 1"

"\x0041"

"\x7f"

"\x41g"

"\x80"

"\200"

"\377"

"\777"

"\x100"

"\x0ff"

"\u00e9"

"\U0001F600"

"\U00110000"

"\N{U+41}"

"\N{U+1F600}"

"\N{LATIN SMALL LETTER A}"

"\N{U+110000}"

"\N{U+D800}"

"\N{U+-41}"

"\N{}"

"\N{U+41"

"\Nx"

"\N{é}"

"\u12"

"\u12

"\x3fff80"

"\x4000041"

"\x10000000"

"\x"

"\C-a"

"\^a"

"\^?"

"\C-?"

"\C-@"

"\C- "

"\C-1"

"\C-é"

"\^\C-a"

"\M-a"

"\M"

"\C"

"\Ca"

; naive: => " "
"\s-a"

"\S-a"

"\S-A"

"\S-1"

"\H-a"

"\A-a"

"\q\z"

"abc

"é∀😀"

"\é"

"a\

"\
"

"\"

"ab"

"tab	here"

"\f"
