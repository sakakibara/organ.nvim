; profile: table
; mode: eval
; case_fold: nil
; Time values: float-time, time-add, time-subtract and the comparisons over every time form, with Emacs's exact conversions and identity shortcuts.

(float-time 0)

(float-time 1700000000)

(float-time -1)

(float-time 1.5)

(float-time '(1 2))

(float-time '(1 2 3))

(float-time '(1 2 3 4))

(float-time '(1 2 . 3))

; naive: => 65538.0
(float-time '(1 2 3 4 5))

(float-time '(-1 65535 999999 999999))

(float-time '(0 0 -1 0))

(float-time '(0 0 0 -1))

(float-time '(0 0 1000000 1000000))

(float-time '(5 . 3))

(float-time '(-5 . 3))

(float-time '(1 . 1000000000))

(float-time '(170000000000000000000000000000 . 100000000000000000000))

(float-time '(1 . 340282366920938463463374607431768211456))

(float-time (cons (expt 10 400) 1))

(float-time (cons 1 (expt 10 400)))

(float-time '(18446744073709551617 . 2))

(float-time 9007199254740993)

(float-time '(1 . 0))

(float-time '(1 . -1))

(float-time '(1 . 1.0))

(float-time '(1.0 . 1))

(float-time "1")

(float-time 'x)

(float-time [1 2])

(float-time '(1 2 3.0))

(float-time '(1 2.0))

(float-time '(1))

(float-time 1.0e+INF)

(float-time -1.0e+INF)

(float-time 0.0e+NaN)

(float-time 4.9e-324)

; naive: => 2.5
(time-add 1.5 1)

(time-add 1 2)

(time-add -1 1)

(time-add 1.25 0.25)

(time-add 0.001 0.002)

(time-add 1e15 0)

(time-add '(1 . 3) '(1 . 6))

(time-add '(1 . 4) '(1 . 4))

(time-add '(2 . 4) 0)

(time-add '(1 . 1000) '(1 . 1000))

(time-add '(1 2) 3)

(time-add '(1 2) '(0 0 1))

(time-add '(1 2 3 4) '(0 0 999997 1))

(time-add '(1 2 3 4) '(5 . 1000))

(time-add '(-1 0) '(0 1 2 3))

(time-add '(1 65535 999999 999999) '(0 0 0 1))

(time-add '(1 . 7) 1)

(time-add (expt 2 70) 1)

(time-add (cons (expt 2 70) 1000) '(0 0 1))

(time-add '(1 . 3) (cons 1 (expt 3 50)))

(time-add '(0 . 1) '(0 0 0 0))

(time-subtract 5 3)

(time-subtract 1.5 0.5)

(time-subtract '(1 2 3 4) '(1 2 3 4))

; naive: !! (error Invalid time specification)
(let ((x '(1 . 0))) (time-subtract x x))

(time-subtract '(1 . 0) 1)

(time-subtract '(3 . 6) '(1 . 4))

; naive: !! (error Invalid time specification)
(time-less-p '(1 . 0) '(2 . 0))

(time-less-p '(1 . 0) '(2 . 1))

(time-less-p 1 2)

(time-less-p 2 1)

(time-less-p 1.5 '(3 . 2))

(time-less-p '(0 1) '(0 1 1))

(time-less-p (expt 2 70) (1+ (expt 2 70)))

(time-less-p '(1 . x) '(2 . x))

(time-less-p "a" 1)

(time-equal-p 1 1.0)

(time-equal-p '(1 . 2) 0.5)

(time-equal-p '(0 1 0 0) 1)

(time-equal-p nil 0)

(time-equal-p 0 nil)

(time-equal-p nil nil)

(let ((x "bad")) (time-equal-p x x))

(time-equal-p "bad" "bad")

(time-add 1.0e+INF 1)

(time-add 0.0e+NaN 1)

(time-add 'x 1)
