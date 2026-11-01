; profile: var
; mode: eval
; case_fold: nil
; Mapping with closures under lexical binding: captured variables, closures in the error data, and setq inside the mapped function.

(let ((n 10)) (mapcar (lambda (x) (+ x n)) '(1 2)))

(let ((n 0)) (mapc (lambda (x) (setq n (+ n x))) [1 2 3]) n)

(let ((n 0)) (list (mapcan (lambda (x) (setq n (1+ n)) (list n x)) "ab") n))

(mapcar (lambda (a b) a) '(1))

(let ((f (lambda (x) (* x 2)))) (mapcar f (mapcar f '(1 2))))

(let ((l (list 1 2 3))) (list (mapcar (lambda (x) (delq 1 l) x) l) l))
