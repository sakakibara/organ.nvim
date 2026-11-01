; profile: table
; mode: eval
; case_fold: nil
; org-lookup-first, -last and -all as org-table.el defines them: PREDICATE called as
; (PREDICATE VAL S), `equal' by default, R-LIST defaulting to S-LIST.

(org-lookup-first 2 '(1 2 3 2) '(a b c d))

(org-lookup-last 2 '(1 2 3 2) '(a b c d))

(org-lookup-all 2 '(1 2 3 2) '(a b c d))

(org-lookup-first 2 '(1 2 3))

(org-lookup-all 2 '(1 2 3 2))

(org-lookup-all 9 '(1 2 3 2))

; naive: => nil
(org-lookup-first "b" '("a" "b") '(1 2))

(org-lookup-first 2 '(1 2 3) nil #'<)

(org-lookup-all 2 '(1 2 3 4) '(a b c d) #'<)

(org-lookup-first 2 '(1 2 3) '(a b c) (lambda (v s) (= v s)))

(org-lookup-first 3 '(1 2 3) '(a))

(org-lookup-first 2 '(1 2 . 3) '(a b c))

(org-lookup-last 2 '(1 2 . 3) '(a b c))

(org-lookup-first 2 [1 2 3] nil)

(org-lookup-first 2 '(1 2) '(a . b))

(org-lookup-last 1 '(1 1) '(a . b))

(org-lookup-first 2 '(1 2) nil 'car)

(org-lookup-first 2 '(1 2) nil 'zzz-organ-elisp-undefined)

(org-lookup-first 1 '(1) '("x"))

(let ((l (list "x"))) (eq (org-lookup-first 1 '(1) l) (car l)))

(let ((l (list 1.5))) (eq (car (org-lookup-all 1 '(1) l)) (car l)))

(org-lookup-all 1 '(1 1) '(1.0 2.0))

(org-lookup-first 1 '(1) nil nil)

(org-lookup-first 1 nil)

(org-lookup-first 1)
