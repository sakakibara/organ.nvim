; profile: table
; mode: eval
; case_fold: nil
; floor, ceiling, round and truncate, with and without a divisor; ffloor, fceiling, fround, ftruncate.

(floor 2.5)

(floor -2.5)

(ceiling 2.5)

(ceiling -2.5)

(truncate 2.7)

(truncate -2.7)

; naive: => 3
(round 2.5)

(round 3.5)

; naive: => -3
(round -2.5)

(round 2.4)

(round 1e+20)

(round 1e+300)

(floor 7)

(floor 7 2)

(floor -7 2)

(floor 7 -2)

(ceiling 7 2)

(ceiling -7 2)

(truncate -7 2)

; naive: => 3
(round 5 2)

(round 7 2)

(round -5 2)

(round -7 2)

; naive: => 3
(round 2.5 1)

(round 1.5 0.5)

(floor 1.5 0.1)

(floor 7 2.5)

(floor -7.5 2)

(ceiling 1 3.0)

(truncate 1e+30 3)

(floor 1000000000000000000000000000000 7)

(round 1000000000000000000000000000000 7)

(ceiling -1000000000000000000000000000000 7)

(round 5e-324 3)

(floor 1e+300 1e-300)

(floor 7 nil)

(floor 1.0e+INF)

(floor -1.0e+INF)

(floor 0.0e+NaN)

(round 1.0e+INF)

(floor 1.0e+INF 2)

(floor 1 0.0e+NaN)

; naive: => -1
(floor -1 1.0e+INF)

(floor 1 -1.0e+INF)

(floor 1.0e+INF 1.0e+INF)

(floor 1 0)

(floor 1 0.0)

(floor 1 -0.0)

(floor 1.5 0)

(floor 'a)

(floor 1 'a)

(floor 'a 0)

(round)

(round 1 2 3)

(ffloor 2.5)

(ffloor -2.5)

(fceiling 2.5)

(fceiling -0.5)

(fround 2.5)

(fround 3.5)

(fround -0.5)

(ftruncate -2.5)

(ftruncate -0.5)

(ffloor 1)

(fround 'a)
