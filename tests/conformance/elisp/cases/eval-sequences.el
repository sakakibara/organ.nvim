; profile: table
; mode: eval
; case_fold: nil
; seq.el functions on lists, vectors and strings: results, the identity of results returned unchanged, and the errors their compiled methods signal.

(list (seq-filter (lambda (x) (> x 1)) '(1 2 3)) (seq-filter #'numberp [1 a 2]) (seq-remove #'null '(1 nil 2)) (seq-filter #'identity "ab"))

(list (seq-map #'1+ [1 2]) (seq-map #'identity "hé") (seq-map #'1+ nil))

(seq-map #'1+ 5)

(seq-filter #'cons '(1))

(list (seq-reduce #'+ '(1 2 3) 10) (seq-reduce #'+ [] 0) (seq-reduce #'cons "ab" nil) (seq-reduce #'+ nil 'init))

(seq-reduce #'+ 5 0)

(seq-reduce #'+ '(1 . 2) 0)

(seq-reduce #'car '(1) 0)

(list (seq-take '(1 2 3) 2) (seq-take [1 2 3] 2) (seq-take "héllo" 2) (seq-take '(1 2) -1) (seq-take [1 2] 9))

(seq-take [1 2 3] 1.5)

(seq-take [1 2 3] 'x)

(seq-take 5 1)

(seq-take '(1 2 . 3) 5)

(seq-take '(1 2 . 3) 2)

(list (seq-drop '(1 2 3) 2) (seq-drop [1 2 3] 2) (seq-drop "héllo" 2) (seq-drop [1 2] 9) (seq-drop 5 0))

(let ((l (list 1 2)) (v (vconcat '(1 2))) (s "ab")) (list (eq (seq-drop l 0) l) (eq (seq-drop v 0) v) (eq (seq-drop s -1) s) (eq (seq-take l 9) l)))

(seq-drop [1 2 3] 1.5)

(seq-drop 5 1)

(list (seq-elt [1 2] 1) (seq-elt '(a b) 1) (seq-elt "hé" 1) (seq-elt '(a) 5))

; naive: !! (wrong-type-argument listp (1 2 . 3))
(seq-elt '(1 2 . 3) 5)

(seq-elt '(1 2 . 3) 200)

(seq-elt [1 2] 5)

(seq-elt 5 0)

(list (seq-first '(a b)) (seq-first [a]) (seq-first "é") (seq-first nil) (seq-rest '(a b)) (seq-rest [1 2]) (seq-rest "ab") (seq-rest nil))

(seq-first [])

(seq-first 5)

(seq-rest 5)

(list (seq-uniq '(1 2 1 3 2)) (seq-uniq [1 1.0 1 "a" "a"]) (seq-uniq "abca") (seq-uniq '("a" "A") (lambda (a b) (string= (downcase a) (downcase b)))))

; naive: => (nil 1)
(seq-uniq '(nil nil 1) #'eq)

(seq-uniq '(1 . 2))

(seq-uniq '(1 2 . 3) #'eq)

(seq-uniq 5)

(let ((l (append '(a a "x" "x" 1.5 1.5 (1 2) (1 2) [3] [3]) (number-sequence 1 100) (number-sequence 50 120) nil))) (length (seq-uniq l)))

(list (seq-contains-p '(1 2 3) 2) (seq-contains-p [1 2] 3) (seq-contains-p "abc" ?b) (seq-contains-p '(1 2) 2 (lambda (a b) 'yes)) (seq-contains-p '("a") "A" #'string=))

(seq-contains-p 5 1)

(seq-contains-p '(1 . 2) 3)

(list (seq-position '(a b c) 'b) (seq-position "abc" ?c) (seq-position [1 2] 3) (seq-position '(1 2 3) 2 #'<))
