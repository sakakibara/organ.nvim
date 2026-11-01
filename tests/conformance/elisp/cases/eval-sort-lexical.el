; profile: prefix
; mode: eval
; case_fold: nil
; sort under lexical binding: closures as predicates and keys, captured counters, and closures among the elements.

(let ((n 0)) (list (sort (list 3 1 2) (lambda (a b) (setq n (1+ n)) (< a b))) n))

(let ((k (lambda (x) (- x)))) (sort (list 1 3 2) :key k))

(let ((f (lambda (x) x))) (eq (car (sort (list f f))) f))

(let ((f (lambda (x) x))) (car (sort (list 2 1) :key (lambda (x) f))))

(sort (list 1 2) (lambda (a b c) a))

(let ((l (list 5 4 3 2 1))) (list (sort l :lessp (lambda (a b) (< a b))) l))
