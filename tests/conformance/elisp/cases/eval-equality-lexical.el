; profile: capture
; mode: eval
; case_fold: nil
; eq, eql and equal under lexical binding: closures compare by identity, and equal of distinct closures refuses.

(eq 'a 'a)

(let ((x 1.5)) (eq x x))

(let ((x 1.5)) (eq x (abs x)))

(let ((f (lambda (x) x))) (eq f f))

(let ((f (lambda (x) x))) (equal f f))

(let ((f (lambda (x) x)) (g (lambda (x) x))) (eq f g))

(let ((f (lambda (x) x)) (g (lambda (x) x))) (equal f g))

(let ((f (lambda (x) x))) (equal f 'car))

(let ((f (lambda (x) x))) (equal f #'car))

(let ((x 1)) (funcall (lambda () (eql x 1))))

(let ((a nil) (b nil)) (dotimes (_ 201) (setq a (list a) b (list b))) (equal a b))
