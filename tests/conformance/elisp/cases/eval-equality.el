; profile: table
; mode: eval
; case_fold: nil
; eq, eql and equal under dynamic binding; organ refuses eq of distinct boxes that could be one object in Emacs.

(eq 'a 'a)

(eq 'a 'b)

(eq nil nil)

(eq 1 1)

(eq 1 1.0)

(eq 2305843009213693951 2305843009213693951)

(eq -2305843009213693952 -2305843009213693952)

(eq 2305843009213693952 2305843009213693952)

(eq 2305843009213693952 2305843009213693953)

(eq 1.0 1.0)

(eq 1.0 2.0)

(eq 0.0 -0.0)

(eq "a" "a")

(eq "a" "b")

(eq [1 2] [1 2])

(eq [1 2] [1 3])

(eq [1] [1 2])

(eq '(1) '(1))

(let ((x '(1))) (eq x x))

(let ((x 1.5)) (eq x x))

(let ((x 1.5)) (eq x (+ x)))

(let ((x 1.5)) (eq x (abs x)))

(let ((x -1.5)) (eq x (abs x)))

(let ((x 1.5)) (eq x (float x)))

(let ((x 1180591620717411303424)) (eq x (round x)))

(let ((x 1180591620717411303424)) (eq x (expt x 1)))

(eq)

(eq 1)

(eql 1 1)

(eql 1 1.0)

(eql 1.0 1.0)

; naive: => t
(eql 0.0 -0.0)

(eql 1180591620717411303424 1180591620717411303424)

(eql "a" "a")

(eql 'a 'a)

(eql 0.0e+NaN 0.0e+NaN)

(let ((x 0.0e+NaN)) (eql x x))

(equal 1 1.0)

(equal 1.0 1.0)

(equal 0.0 -0.0)

(equal "abc" "abc")

(equal "abc" "abd")

(equal '(1 (2 "x") . 3) '(1 (2 "x") . 3))

(equal '(1 2) '(1 2 3))

(equal [1 (2) "x"] [1 (2) "x"])

(equal [1 2] '(1 2))

(equal 1180591620717411303424 1180591620717411303424)

(equal 'a 'a)

(equal 0.0e+NaN 0.0e+NaN)

(let ((x 0.0e+NaN)) (equal (list x) (list x)))

(equal #'car #'car)

(equal (function car) 'car)

(let ((a nil) (b nil)) (dotimes (_ 200) (setq a (list a) b (list b))) (equal a b))

; naive: => t
(let ((a nil) (b nil)) (dotimes (_ 201) (setq a (list a) b (list b))) (equal a b))

(let ((a 1) (b 2)) (dotimes (_ 300) (setq a (list a) b (list b))) (equal a b))

(let ((x (list 1))) (let ((a x) (b x)) (dotimes (_ 300) (setq a (list a) b (list b))) (equal a b)))

(let ((a 'x)) (dotimes (_ 300) (setq a (cons a a))) (equal a (cons (car a) (cdr a))))

(let ((a 1) (b 1)) (dotimes (_ 199) (setq a (cons nil a) b (cons nil b))) (equal (list a) (list b)))

(let ((a 1) (b 1)) (dotimes (_ 1000) (setq a (cons 1 a) b (cons 1 b))) (equal a b))

(equal)
