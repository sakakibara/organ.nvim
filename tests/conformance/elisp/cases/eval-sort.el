; profile: table
; mode: eval
; case_fold: nil
; sort: Emacs 31's calling conventions and keywords, the value< order, and the timsort's order under predicates that are not strict orders.

(list (sort '(3 1 2) #'<) (sort [3 1 2] #'<) (sort '(3 1 2)) (sort '(b a c)) (sort '("b" "a")) (sort '(3 1 2) nil))

(let ((l (list 3 1 2))) (list (sort l #'<) l))

(let ((l (list 3 1 2))) (list (sort l) l))

(let ((l (list 3 1 2))) (list (sort l :in-place t) l))

(let ((v (vconcat '(3 1 2)))) (list (sort v) v (sort v :in-place t) v))

(list (sort '(3 1 2) :reverse t) (sort '((1 . b) (0 . a) (1 . a)) :key #'car) (sort '((1 . b) (0 . a) (1 . a)) :key #'car :reverse t) (sort '(3 1 2) :lessp #'> :key 'identity))

(let ((l (list 1))) (list (eq (sort l) l) (eq (sort l :in-place t) l) (sort nil) (sort [])))

(sort '(1 2) :foo 1)

(sort '(1 2) nil 1 2 3)

(sort '(1 2) '(1 2) 3)

(sort '(1 2) :key 1 2)

(sort 5)

(sort '(1 . 2))

(sort '(2 1) #'car)

(sort '(2 1) :key #'cons)

(sort '(2 1) 'when)

(sort '(2 1) 'if)

; naive: => (3 1 2)
(sort '(3 1 2) (lambda (a b) t))

; naive: => (1 2 3 4 5 6 7 8)
(sort '(5 3 8 1 6 2 7 4) (lambda (a b) (< (% (+ a b) 5) 2)))

(sort (number-sequence 1 100) (lambda (a b) (> (% (* a 31) 17) (% b 13))))

(sort (vconcat (number-sequence 100 1 -1) (number-sequence 1 100)) (lambda (a b) (< (% a 7) (% b 7))))

(sort (append (number-sequence 1 70) (number-sequence 70 1 -1) nil) :key (lambda (x) (% x 5)) :reverse t)

(let ((l (list 3 1 2))) (list (condition-case e (sort l (lambda (a b) (if (= a 2) (car a) (< a b)))) (error e)) l))

(let ((v (vconcat '(3 1 2)))) (list (condition-case e (sort v :reverse t :in-place t :lessp (lambda (a b) (car a))) (error e)) v))

(let ((v (vconcat (number-sequence 1 10) '(0)))) (list (condition-case e (sort v :in-place t :lessp (lambda (a b) (if (= a 0) (car a) (< a b)))) (error e)) v))

(let ((v (vconcat (number-sequence 1 64) (number-sequence 64 1 -1))) (n 0)) (list (condition-case e (sort v :in-place t :lessp (lambda (a b) (setq n (1+ n)) (if (= n 150) (car a) (< a b)))) (error e)) v))

(let ((v (vconcat (number-sequence 1 300) (number-sequence 300 1 -1))) (n 0)) (list (condition-case e (sort v :in-place t :lessp (lambda (a b) (setq n (1+ n)) (if (= n 700) (car a) (< a b)))) (error e)) (equal (sort (append v nil) #'<) (sort (append (number-sequence 1 300) (number-sequence 1 300) nil) #'<)) (seq-take v 12)))

(let ((v (vconcat (number-sequence 1 75) (number-sequence 75 1 -1))) (n 0)) (list (condition-case e (sort v :in-place t :key #'- :lessp (lambda (a b) (setq n (1+ n)) (if (= n 200) (car a) (< a b)))) (error e)) (equal (sort (append v nil) #'<) (sort (append (number-sequence 1 75) (number-sequence 1 75) nil) #'<)) (seq-take v 12)))

(let ((l (number-sequence 1 300))) (list (condition-case e (sort l :in-place t :lessp (lambda (a b) (car a))) (error e)) (eq (car l) 1) (length l)))

(list (sort (list 4611686018427387904 1.5 -4611686018427387905 1.0e+INF 2)) (sort (list -0.0 0.0)) (sort (list 0.0 -0.0)))

(list (sort (list nil '(1))) (sort (list '(1) nil)) (sort (list '(1 2) '(1))) (sort (list [1 2] [1])) (sort (list 'b "a" 'a) :key (lambda (x) (if (symbolp x) (symbol-name x) x))))

(sort (list 1 "a"))

(sort (list "a" 1))

(sort (list 'a 4611686018427387904))

; naive: !! (type-mismatch 4611686018427387904 a)
(sort (list 4611686018427387904 'a))

(sort (list 4611686018427387904 [1]))

(sort (list '(1) 4611686018427387904))

(sort (list '(1 2) '(1 . 2)))

(sort (list '(1 . 2) '(1 2)))

(sort (list [1 "a"] [1 2]))

(let ((a 1) (b 2)) (dotimes (_ 199) (setq a (list a) b (list b))) (sort (list b a)))

(let ((a 1) (b 2)) (dotimes (_ 200) (setq a (list a) b (list b))) (car (sort (list b a))))

(let ((a 1) (b 2)) (dotimes (_ 201) (setq a (list a) b (list b))) (car (sort (list b a))))

(let ((a 1) (b 2)) (dotimes (_ 201) (setq a (vconcat (list a)) b (vconcat (list b)))) (car (sort (list b a))))

(sort (list 0.0e+NaN 1))

(sort (list (lambda (x) x) (lambda (x) x)))

(sort (list 1 2) :lessp 'value<)
