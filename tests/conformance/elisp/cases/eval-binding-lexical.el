; profile: capture
; mode: eval
; case_fold: nil
; Bindings: let, let*, setq, dolist, dotimes, closures, specials, free variables, lexical binding.
; The setq of a global comes last: Emacs sets it.

(let ((x 1) y (z)) (list x y z))

(let ((x 1)) (let ((x 2) (y x)) (list x y)))

(let* ((x 1) (y (cons x x))) y)

(let ((x 1 2)) x)

(let* ((x 1 2)) x)

(let ((x 1 . 2)) x)

(let (1) 1)

(let* (1) 1)

(let ((1 2)) 1)

(let* ((1 2)) 1)

(let x 1)

; naive: !! (wrong-type-argument listp (x . y))
(let (x . y) 1)

(let* (x . y) 1)

(let ((x . 1)) x)

(let* ((x . 1)) x)

(let ((nil 1)) 1)

(let ((t 1)) 1)

(let ((:k 1)) 1)

; naive: !! (setting-constant :k)
(let ((:k :k)) :k)

(let* ((nil 1)) 1)

(let)

(let*)

(let ())

(let* () 1 2)

(let ((x (car 1)) (1 2)) 1)

(let ((x 1)) (setq x 2) x)

(let ((x 1) (y 2)) (setq x 3 y x) (list x y))

(setq)

(let ((x 1)) (setq x))

(let ((x 1)) (list (condition-case e (setq x 2 y) (error e)) x))

(setq nil 1)

(setq t 1)

(setq :k :k)

(setq :k 1)

(setq 1 2)

(let ((x 1)) (setq x 1 . 2))

(let ((x 1)) (setq x (cons x x)))

(let (acc) (dolist (x '(1 2 3)) (setq acc (cons x acc))) acc)

(let (acc) (dolist (x '(1 2 3) (cons 'r acc)) (setq acc (cons x acc))))

(dolist (x nil 5))

(dolist (x '(1 2) x))

(let ((x 'outer)) (dolist (x '(1 2) x)))

(let (acc) (dolist (x '(1 2 3)) (setq acc (cons x acc)) (setq x 10)) acc)

(dolist (x '(1 . 2)))

(dolist (x 5))

(dolist x)

(dolist (x))

(dolist (x 1 2 3))

(dolist)

(dolist (1 '(2)))

(dolist (x '(1)) . 2)

(dolist (x . 1))

(dolist (x '(1) . 2))

(let (acc) (dotimes (i 3) (setq acc (cons i acc))) acc)

; naive: => 2
(dotimes (i 3 i))

(dotimes (i 2.5 i))

(dotimes (i 0 i))

(dotimes (i -1 i))

(dotimes (i "a"))

(dotimes (i))

(dotimes x)

(dotimes (1 3))

(dotimes)

(dotimes (i 3 1 2))

(let (acc) (dotimes (i 3) (setq acc (cons i acc)) (setq i 10)) acc)

(dotimes (i 3 (list i)))

(dotimes (i 3.0 i))

(dotimes (i -100000000000000000000 i))

(dotimes (i '(1)))

(dotimes (i . 3))

(dotimes (i 3 . 4))

(dotimes (i 2) . 5)

(let (fs) (dolist (x '(1 2 3)) (setq fs (cons (lambda () x) fs))) (list (funcall (car fs)) (funcall (car (cdr fs)))))

(let (fs) (dotimes (i 3) (setq fs (cons (lambda () i) fs))) (list (funcall (car fs)) (funcall (car (cdr fs)))))

(let ((x 1)) (let ((f (lambda () x))) (setq x 2) (funcall f)))

(let ((f (let ((x 1)) (lambda () x)))) (funcall f))

(let ((f (let ((x 1)) (lambda () (setq x (cons x x)) x)))) (funcall f) (funcall f))

(let ((x 1)) (funcall '(lambda () x)))

(let ((x 1)) (funcall (lambda (y) (list x y)) 2))

(funcall (let ((x 1)) (lambda (x) x)) 2)

(funcall (lambda (nil) nil) 2)

(funcall (lambda (t) t) 2)

(funcall (lambda (:k) :k) 2)

(funcall '(lambda (nil) nil) 2)

(let ((case-fold-search t)) case-fold-search)

(let ((case-fold-search t)) (setq case-fold-search 5) case-fold-search)

(let ((calendar-date-style 'iso)) calendar-date-style)

(let ((fill-column 3)) 1)

(let* ((fill-column 3)) 1)

(dolist (fill-column '(1)))

(dotimes (fill-column 1))

(funcall (lambda (fill-column) fill-column) 3)

(condition-case fill-column (car 1) (error fill-column))

(let ((case-fold-search 'x)) (funcall '(lambda () case-fold-search)))

(let ((y 1)) (funcall '(lambda () y)))

calendar-date-style

(let ((pi 3)) pi)

(funcall (lambda (case-fold-search) case-fold-search) 'x)

(let ((f (lambda () case-fold-search))) (let ((case-fold-search 'y)) (funcall f)))

(setq fill-column 3)

(setq case-fold-search t)

(setq zzz-organ-elisp-global 1)
