; profile: table
; mode: eval
; case_fold: nil
; Integer and float arithmetic: contagion over all arguments, argument checks in order, division and remainders.

(+)

(+ 1 2 3)

(+ 1 2.5)

(+ 'a)

(+ 1 'a)

(+ 'a 1)

(-)

(- 5)

(- 0)

(- 1.5)

(- 10 1 2)

(- 10 1 2.0)

(*)

(* 2 3 4)

(* -3 0)

(* 2 0.5)

; naive: => 1.5
(/ 7 2 2.0)

(/ 7 2.0 2)

(/ 7 2)

; naive: => -4
(/ -7 2)

(/ 7 -2.0)

(/ 2)

(/ -1)

(/ 0)

(/ 4.0)

(/ 0.0)

(/ 5 0)

(/ 5 0 'a)

(/ 5 'a 0)

; naive: !! (arith-error)
(/ 5 0 2.0)

(/ 5.0 0)

(/ -5.0 0)

(/)

(% 7 3)

(% -7 3)

(% 7 -3)

(% 7 0)

(% 7.0 2)

(% 7 'a)

; naive: => -2
(mod -5 3)

(mod 5 -3)

(mod -6 3)

(mod 5 0)

(mod 5.5 2)

; naive: => 1.5
(mod 5.5 -2)

(mod -0.0 1)

(mod 5 'a)

(1+ 1)

(1+ -1)

(1+ 1.5)

(1- 0)

(1- -1.0)

(1+ 'a)

(1+ nil)

(abs -5)

(abs 5)

(abs -2.5)

; naive: => -0.0
(abs -0.0)

(abs 'a)

; naive: => 2.0
(max 2 1.0)

(max 1 1.0)

(max 1.0 1)

(min 1.0 1)

(min 3 1 2)

(max 1 2.5 2)

(max 'a)

(max 1 'a)

(max)

(float 3)

(float -0.0)

(float 'a)

(+ 1 2 3 4 5 6 7 8 9 10)
