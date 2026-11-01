; profile: table
; mode: eval
; case_fold: nil
; Mapping: mapcar, mapc and mapcan over lists, vectors and strings, the arity data through funcall, and lists changed while mapping.

(list (mapcar #'1+ '(1 2)) (mapcar #'1+ [1 2]) (mapcar #'identity "hé") (mapcar #'1+ nil))

(let ((l (list 1 2))) (eq (mapc #'ignore l) l))

(mapcan (lambda (x) (list x x)) '(1 2))

(mapcan #'identity '((1) 2 (3)))

(mapcan #'identity '((1) (2) 3))

(mapcan #'list "ab")

(let ((l (list 1))) (mapcan (lambda (x) l) '(1 2)))

(mapcar #'1+ '(1 . 2))

(mapcar #'1+ 5)

(mapc #'1+ 5)

(mapcar #'cons '(1))

(mapcar (lambda (a b) a) '(1))

(mapcar 'cadr '(1))

(mapcar 'when '(1))

(mapcar 'if '(1))

; naive: => ((1 2 3) (1 3))
(let ((l (list 1 2 3))) (list (mapcar (lambda (x) (delq 2 l) x) l) l))

(let ((l (list 1 2 3))) (list (mapc (lambda (x) (delq 2 l) x) l) l))

(let ((l (list 1 2 3))) (list (mapcan (lambda (x) (delq 2 l) (list x)) l) l))

(let ((l (list 1 2 3 4))) (list (mapcar (lambda (x) (nreverse l) x) l) l))

(let ((l (list 1 2 3 4))) (list (mapcar (lambda (x) (nconc l (list 9)) x) l) l))

(let ((l (list 3 1 2))) (list (mapcar (lambda (x) (sort l #'<) x) l) l))

(let ((v (vconcat '(3 1 2)))) (list (mapcar (lambda (x) (sort v :in-place t) x) v) v))

(let ((l (list "a" "b" "c"))) (mapconcat (lambda (x) (nconc l (list "d")) x) l "-"))
