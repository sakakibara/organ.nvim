; profile: var
; mode: eval
; case_fold: nil
; Time values under lexical binding: through funcall, apply and mapcar, wrong argument counts, and shared objects.

(let ((a 1.5) (b '(1 . 4))) (list (time-add a b) (time-subtract a b) (time-less-p b a)))

(let ((x '(1 . 0))) (list (time-subtract x x) (time-equal-p x x)))

(mapcar #'float-time '(1 (1 . 4) (0 1 2 3)))

(funcall #'time-add 1 2)

(apply #'time-add '(1 2 3))

(time-add 1)

(funcall #'time-add 1)

(let ((h (expt 2 70))) (eq (cdr (time-add (cons 1 h) (cons 2 h))) h))
