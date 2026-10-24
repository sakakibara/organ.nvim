; profile: table
; mode: read
; Symbols: escapes, number-like names and how they print.

foo

nil

t

:kw

()

a\ b

\1

\-1

\+1

\1.

\1e5

\.5

\.

..

; naive: => \.a
.a

; naive: => \.e5
.e5

a.b

a?b

\?a

; naive: => a\?
a\?

-

+

1+

-.

-1x

\1.0e+INF

é

a\(b

\#

\;

\"

\'

\`

\,

\,@

\[\]

\ 

a b

a b

(a b)

 x

(a#b)

(a,b)

(a'b)

(a`b)

(a"b")

(a;b
 c)

foo\

\

abc\	def

##

#:foo

#:

#_foo

#_

a#

a?

a.

\ 

λ

(intern)

\nil

a|b

a{b}

1.5x
