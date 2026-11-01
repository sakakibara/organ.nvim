; profile: table
; mode: eval
; case_fold: nil
; Destructive operations: nconc, nreverse, delq, delete and delete-dups mutate conses in place as Emacs does; nconc refuses to make a cycle.

(let ((a (list 1 2)) (b (list 3))) (list (nconc a b) a b))

(list (nconc) (nconc nil) (nconc 5) (nconc nil nil 5) (nconc (list 1) 5))

(let ((a (list 1)) (b (list 2))) (list (nconc a nil b) a))

(nconc '(1 . 2) '(3))

(nconc 5 '(1))

(nconc (list 1) 5 (list 2))

(let ((l (list 1 2))) (nconc l l))

(let ((l (list 1 2))) (nconc l (cdr l)))

(let ((l (list 1 2))) (nconc (list 0) l l))

(let ((l (list 1 2))) (nconc l (list l)))

(let ((l (list 1 2 3))) (list (nreverse l) l))

(let ((v (vconcat '(1 2 3)))) (list (nreverse v) v))

(let ((s "abc")) (list (nreverse s) s))

(nreverse (list 1 2 'x))

; naive: !! (wrong-type-argument listp 3)
(nreverse '(1 2 . 3))

(nreverse 5)

(let ((l (list 1 2 1 3 1))) (list (delq 1 l) l))

(let ((l (list 1 2))) (eq (delq 9 l) l))

; naive: !! (wrong-type-argument listp (1 . 2))
(delq 1 '(1 . 2))

(delq 3 '(1 . 2))

(let ((l (list "a" "b" "a"))) (list (delete "a" l) l))

(let ((v (vconcat '(1 2 1)))) (list (delete 1 v) v (eq (delete 9 v) v)))

(let ((s "banana")) (list (delete ?a s) (eq (delete ?z s) s) (eq (delete 'a s) s)))

(delete ?é "héé")

(delete 1 '(1 . 2))

(delete 9 5)

(let ((l (list 1 2))) (list (remove 1 l) l (remove 3 [1 3 3])))

(let ((v (vconcat '(1 2)))) (eq (remove 9 v) v))

(remove 1 '(1 2 . 3))

(let ((l (list 1 2 1))) (list (remq 1 l) l (eq (remq 9 l) l) (eq (remq 1 (cons 1 l)) l)))

(remq 1 '(2 1 . 3))

(remq 9 '(2 1 . 3))

(remq 1 5)

(let ((l (list 1 "a" 1 "a" '(x) '(x) 2.0 2.0 2))) (list (delete-dups l) l))

(delete-dups (list 1.0 1 1.0 -0.0 0.0))

(delete-dups [1 2])

(delete-dups "")

(delete-dups '(1 . 2))

(delete-dups 5)

(let ((l (append (number-sequence 1 120) (number-sequence 100 130) '("a" "a" a a 1.5 1.5 (1) (1) [2] [2]) nil))) (list (length (delete-dups l)) (nthcdr 125 l)))

(let ((a 0) (b 0)) (dotimes (_ 250) (setq a (list a) b (list b))) (delete-dups (list a b)))

(let ((a 0) (b 0)) (dotimes (_ 250) (setq a (list a) b (list b))) (delete-dups (append (number-sequence 1 101) (list a b) nil)))

(delete-dups (list 0.0e+NaN 0.0e+NaN))

(let ((x 0.0e+NaN)) (delete-dups (list x x)))

(let ((x 0.0e+NaN)) (length (delete-dups (append (number-sequence 1 101) (list x x) nil))))
