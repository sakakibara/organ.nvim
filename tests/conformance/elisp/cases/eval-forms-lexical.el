; profile: capture
; mode: eval
; case_fold: nil
; Special forms, function position, calls and constants, lexical binding.

(quote a)

(quote)

(quote a b)

'(1 . 2)

(function car)

(function)

(function a b)

(funcall #'(lambda (x) (cons x x)) 1)

(if t 1 2)

(if nil 1 2 3)

(if nil 1)

(if)

(if t)

(if t . 1)

(if nil 1 . 2)

(cond)

(cond (nil 1) (t 2))

(cond (1))

(cond ((car '(nil))) ((car '(5)) 6 7))

(cond 1)

(cond (nil) . 3)

(cond ((car '(5)) . 6))

(and)

(and 1 2)

(and 1 nil (car 1))

(or)

(or nil 2)

(or nil nil)

(or 1 (car 1))

(progn)

(progn 1 2)

(progn 1 . 2)

(prog1 1 2 3)

(prog1)

(prog1 (car '(1)) (car 1))

(prog2 1 2 3)

; naive: !! (wrong-number-of-arguments prog2 1)
(prog2 1)

(prog2)

(when t 1 2)

(when nil 1)

(when t)

; naive: !! (wrong-number-of-arguments when 0)
(when)

(when t . 1)

(unless nil 1 2)

(unless t 1)

(unless nil)

(unless)

(let ((x '(1 2 3)) (acc nil)) (while x (setq acc (cons (car x) acc)) (setq x (cdr x))) acc)

(while nil 1)

(while)

(while nil . 1)

(identity 1)

(identity)

(identity 1 2)

(ignore)

(ignore 1 (car '(2)))

(ignore (car 1))

; naive: !! (wrong-type-argument listp 1)
(car (car 1) 2)

(funcall #'car (car 1) 2)

(identity (car 1) 2)

(ignore . 1)

(car . 1)

(error "x" (car 1))

(cons 1 2)

(cons 1)

(list)

(list 1 '(2) "s")

(car '(1 2))

(cdr '(1 2))

(car nil)

(cdr nil)

(car 'a)

(cdr "s")

(car)

(1 2)

((1) 2)

((foo) 1)

(nil)

("s")

([1] 2)

(1.5)

(foo 1)

(nil 1 . 2)

((closure (t) (x) x) 1)

((macro . car) 1)

nil

t

:k

pi

float-pi

float-e

(list pi float-pi)

case-fold-search

foo

1

"s"

[a (b)]

1.5

(car 1

(funcall (lambda (&optional a &rest b) (list a b)))

(funcall (lambda (&optional a &rest b) (list a b)) 1 2 3)

(funcall (lambda (a &optional b) (list a b)) 1)

(funcall (lambda (a a) a) 1 2)

(funcall (lambda (&rest a b) (list a b)) 1 2)

(funcall (lambda (&optional) 1))

(funcall (lambda (&rest) 1))

(funcall (lambda (1) 1) 2)

(funcall (lambda (&optional &optional a) a))

(funcall (lambda (&rest a &optional b) a) 1)

(funcall (lambda (&optional &rest a) a) 1)

(funcall (lambda (x) "doc" x) 1)

(funcall (lambda () "doc"))

(funcall (lambda (x) (interactive) x) 1)

(funcall (lambda (x) (:documentation (car '(a))) x) 1)

(funcall (lambda (x) (:documentation (car 1)) x) 1)

(funcall (lambda))

(funcall (lambda (x) . 5) 1)

(funcall (lambda x 1))

((lambda (x) (list x)) 1)

((lambda (x) x))

((lambda (x) x) 1 2)

(funcall '(lambda (x) (list x)) 1)

(funcall '(lambda (x) x))

(funcall '(lambda x 1))

(funcall '(lambda))

(funcall '(lambda (1) 1) 2)

(funcall '(closure (t) (x) x) 1)

(funcall '(foo 1))

(funcall '(1 2))

(funcall nil)

(funcall 1)

(funcall "s")

(funcall [1])

(funcall #'quote 1)

(funcall 'when t)

(funcall 'if t 1)

(funcall 'lambda)

(funcall '\` 1)

(funcall)

(funcall #'funcall #'list 1 2)

(funcall 'list 1 2)

(funcall 'foo)

(funcall t)

(funcall :k)

(apply #'list 1 2 '(3 4))

(apply #'list nil)

(apply #'list 1 nil)

(apply '(list 1 2))

(apply '(identity))

(apply 'identity)

(apply)

(apply nil)

(apply #'identity 1)

(apply #'identity '(1 . 2))

(apply #'identity '(1 2))

(apply #'apply #'list '((1 2)))

(apply #'list '(1))

(apply #'list 1 '(2))

(apply 'when '(t))

(funcall #'car)

(funcall #'identity 1 2)

(apply #'cons '(1))

(funcall #'error)

(funcall #'user-error)

(funcall #'signal)

(funcall #'apply)

(funcall #'funcall)

(funcall #'list)

(funcall #'ignore 1 2)
