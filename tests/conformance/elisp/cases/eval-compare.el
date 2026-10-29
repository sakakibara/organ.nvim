; profile: table
; mode: eval
; case_fold: nil
; Numeric comparison: exact between integers and floats, lazy argument checks, NaN unordered.

(= 1 1)

(= 1 1.0)

(= 1 1 1 2)

(= 0.0 -0.0)

; naive: !! (wrong-type-argument number-or-marker-p a)
(= 'a)

; naive: !! (wrong-type-argument number-or-marker-p a)
(< 2 1 'a)

(< 1 2 'a)

(< 'a 1)

(< 1 2 3)

(< 1 3 2)

(> 3 2 1)

(<= 1 1 2)

(>= 2 2 3)

(< 1.5 2)

(/= 1 2)

(/= 1 1.0)

(/= 1 'a)

(/= 1)

(=)

(= 9007199254740993 9007199254740992.0)

(< 9007199254740992.0 9007199254740993)

(> 9007199254740993 9007199254740992.0)

(= 0.0e+NaN 0.0e+NaN)

(< 0.0e+NaN 1)

(/= 0.0e+NaN 0.0e+NaN)

(< 1 1.0e+INF)

(> -1.0e+INF -100000000000000000000000)

(zerop 0)

(zerop 0.0)

(zerop -0.0)

(zerop 1)

(zerop 'a)

(zerop)

(zerop 1 2)
