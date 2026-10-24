; profile: table
; mode: read
; Lists, dotted pairs, vectors, comments, read errors and refused syntax.

()

(a)

(a b c)

(a . b)

(a . (b))

(a . (b . c))

(a .b)

(a .5)

(a . 5)

; naive: !! (invalid-read-syntax .)
(a .)

(. a)

(a . b c)

(a . )

(a . b . c)

(a .
 b)

(a . ;c
 b)

; naive: => (a . 'b)
(a . 'b)

(a . "x")

(a.b)

((a . b) . c)

[1 2]

[]

[a . b]

[(a . b)]

([1] (2))

[a [b [c]]]

(a ; comment
 b)

; c
1

1 ; trailing

   

; only

(

(a

[a

)

]

(a]

[a)

(a . b]

(a b

("a" . "b")

(1 2 . 3)

#s(foo)

#s(hash-table data (a 1))

#sx

#s

#&8"a"

#@5 abcde

#$

#1=(a . #1#)

#1#

#1=x

#<buffer x>

#("a" 0 1 (face bold))

#[1 2]

#^[nil]

#^^[3 0]

#^x

#^^x

#^

#!x
1

#a

#

#1

#1x

#12

#'x

#X10

#
1

(a #! b
 c)

 1

(a	b)

(a
b)
