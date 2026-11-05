; profile: table
; mode: eval
; case_fold: nil
; Float functions through libm, float printing, infinities and NaN, which organ refuses to print or compare by contents. A NaN libm returns is printed through abs, as its sign is the platform's.

(sqrt 4)

(sqrt 2)

(abs (sqrt -1))

(sqrt 1180591620717411303424)

(exp 0)

(exp 1)

(exp 1000)

(exp -1000)

(log 1)

(log 0)

(abs (log -1))

(log 8 2)

(log 100 10)

(log 1000 10.0)

(log 27 3)

(log 2 nil)

(log 'a)

(log 8 'a)

(sin 0)

(sin 1)

(cos 1)

(tan 1.5)

(asin 1)

(abs (asin 2))

(acos 0.5)

(atan 1)

(atan 1 -1)

(atan 1 nil)

(atan -0.0 -1)

(atan 'a)

(atan 1 'a)

(expt 2.0 0.5)

(expt 1.1 10)

(expt 2 0.5)

(expt -8 1.0e+INF)

(abs (expt -8.0 (/ 1.0 3)))

(expt 0.0 0)

(expt 10 -2)

(expt 'a 1)

(expt 2 'a)

(isnan 0.0e+NaN)

(isnan 1.0)

(isnan 1)

(floatp 1.0)

(floatp 1)

(numberp 1.0)

(integerp 1.0)

1e+21

1e-07

123456789.123

0.1

(/ 1.0 3)

(* 1.0e+308 10)

(- 0.0)

(+ -0.0 0.0)

(* -1 0.0)

(/ 1 -0.0)
