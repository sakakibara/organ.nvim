; profile: capture
; mode: eval
; case_fold: nil
; Numbers under lexical binding, and zerop's compiler macro in closures created where a variable is bound.

(let ((x 7)) (/ x 2 2.0))

(let ((x 2.5)) (round x))

(let ((y 1)) (funcall (lambda (x) (zerop x)) 0))

(let ((y 1)) (funcall (lambda (x) (zerop x)) 0.0))

(let ((y 'a)) (funcall (lambda () (zerop y))))

(let ((y 1)) (funcall (lambda (x) (zerop)) 0))

(let ((y 1)) (funcall (lambda (x) (zerop x y)) 0))

(let ((y 1)) (funcall (lambda () (+ y (expt 2 70)))))

(let ((y 1)) (funcall (lambda () (logand y -1 (ash y 64)))))

(funcall (lambda (x) (zerop x)) 0)
