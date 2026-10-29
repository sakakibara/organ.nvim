; profile: table
; mode: eval
; case_fold: nil
; logand, logior, logxor, lognot and ash on fixnums and bignums, as two's complement.

(logand)

(logior)

(logxor)

(logand 12 10)

(logior 12 10)

(logxor 12 10)

(logand -1 5)

(logand -12 10)

(logior -12 10)

(logxor -12 10)

(logand 12 10 6)

(logxor 5)

(logand 'a)

; naive: !! (wrong-type-argument integer-or-marker-p a)
(logand 1 'a)

(logand 1 1.0)

(logand 1.0)

(logior 1.5 2)

(logand -1 1180591620717411303424)

(logand 1180591620717411303425 -2)

(logxor -12345678901234567890123 98765432109876543210)

(logior -3 -1208925819614629174706176)

(logand -1180591620717411303424 -1180591620717411303425)

(logand 281474976710655 16777216)

(logxor 9007199254740991 -9007199254740992)

(lognot 0)

(lognot 5)

(lognot -6)

(lognot 1180591620717411303424)

(lognot 1.0)

(ash 1 10)

(ash 5 -1)

; naive: => -2
(ash -5 -1)

(ash -5 -100)

(ash 5 -100)

(ash 1 100)

(ash -1 100)

(ash 1180591620717411303424 -70)

(ash -1180591620717411303425 -70)

(ash 1180591620717411303424 0)

(ash 1 65536)

(ash -1 65536)

(ash 0 137438953407)

(ash 0 137438953408)

(ash 0 36028797018963968)

(ash 0 1180591620717411303424)

(ash 5 -36028797018963968)

(ash -5 -1180591620717411303424)

(ash 5 1180591620717411303424)

(ash 1.0 1)

(ash 1 1.0)
