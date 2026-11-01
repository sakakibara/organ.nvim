; profile: table
; mode: eval
; case_fold: nil
; Lists: building, accessing and searching, with Emacs's error data and the identity of results returned unchanged.

(list (car-safe '(1 . 2)) (car-safe 1) (cdr-safe '(1 . 2)) (cdr-safe "a"))

(list (caar '((1) 2)) (cadr '(1 2)) (cdar '((1 . 2))) (cddr '(1 2 3)))

(cadr 5)

(cddr '(1 . 2))

(list (nth 0 '(a b)) (nth 1 '(a b)) (nth 5 '(a b)) (nth -1 '(a b)))

; naive: !! (wrong-type-argument listp 2)
(nth 3 '(1 . 2))

(nth -1 5)

(nth 1.0 '(1 2))

(list (nth 4611686018427387904 '(1 2)) (nth -4611686018427387905 '(1 2)))

(nthcdr 2 [1 2 3])

(let ((l (list 1 2))) (list (eq (nthcdr 0 l) l) (eq (nthcdr -3 l) l) (nthcdr 2 l)))

(list (elt '(a b c) 1) (elt [a b c] 1) (elt "héllo" 1) (elt '(a) 5))

(elt '(1 . 2) 3)

(elt 5 0)

(elt [1 2] 4611686018427387904)

(aref "héllo" 4)

(aref "ab" 2)

(aref [1 2] -1)

(aref [1 2] 1.0)

(aref '(1) 0)

(list (last '(1 2 3)) (last '(1 2 3) 2) (last '(1 2 3) 0) (last '(1 2 3) 9) (last nil))

; naive: => nil
(last 5)

(last '(1 2 . 3))

(last '(1 2 3) -1)

(last '(1 2 3) 'a)

(last '(1 2 3) 1.5)

(let ((l (list 1 2))) (eq (last l 5) l))

(list (butlast '(1 2 3)) (butlast '(1 2 3) 2) (butlast '(1 2 3) 5) (butlast "abc" 5))

(let ((l (list 1 2))) (eq (butlast l 0) l))

(butlast "abc")

(butlast '(1 2 . 3))

(butlast '(1 2 3) 1.0)

(list (number-sequence 1 10 3) (number-sequence 5 1 -2) (number-sequence 3) (number-sequence 3 3 0) (number-sequence 5 1))

; naive: => (0 0.1 0.2 0.30000000000000004 0.4 0.5 0.6 0.7 0.7999999999999999 0.8999999999999999 0.9999999999999999)
(number-sequence 0 1 0.1)

(number-sequence 4611686018427387900 4611686018427387905 2)

(number-sequence 1 2 0)

(number-sequence 'a)

(number-sequence 1 'b)

(number-sequence 1 2 'c)

(list (append) (append nil) (append '(1) [2] "é" nil) (append '(1) 'x) (append nil nil 5))

(let ((l (list 1))) (list (eq (append l) l) (eq (append nil l) l) (eq (append l nil) l)))

(append '(1 . 2) nil)

(append 5 nil)

(list (vconcat) (vconcat '(1) [2] "é" nil))

(vconcat '(1) 5)

(vconcat '(1 . 2) 5)

(list (reverse '(1 2 3)) (reverse [1 2 3]) (reverse "héllo") (reverse nil) (reverse []))

(reverse '(1 2 . 3))

(reverse 5)

(list (member "b" '("a" "b" "c")) (member 1.0 '(1 1.0)) (member '(1) '((1))) (member 3 '(1 2)))

(member 3 '(1 . 2))

(list (memq 'b '(a b c)) (memq 2 '(1 2)) (memql 1.0 '(1 1.0)) (memql 4611686018427387904 '(4611686018427387904)))

(memq 'z '(a b . c))

(memq 'b '(a b . c))

(list (assq 'b '((a . 1) 2 (b . 3))) (assoc "b" '(("a" . 1) ("b" . 2))) (assoc 2.0 '((2 . a) (2.0 . b))) (rassq 1 '((a . 1))) (rassoc "x" '((a . "x"))))

(assq 'a '((b . 1) . 5))

(assoc 2 '((1 . a) (2 . b)) (lambda (a b) (> a b)))

(assoc 'a '((b . 1)) 5)

(list (alist-get 'b '((a . 1) (b . 2))) (alist-get 'c '((a . 1)) 'none) (alist-get "a" '(("a" . 1)) nil nil #'string=) (alist-get 'x '(1 (x . 3))))

(alist-get 'x 5)
