; profile: table
; mode: eval
; case_fold: nil
; Type predicates, identity and ignore.

(null nil)

(null 'a)

(not nil)

(not 0)

(atom 1)

(atom '(1))

(atom [1])

(atom nil)

(consp '(1))

(consp nil)

(listp nil)

(listp '(1 . 2))

(listp [1])

(nlistp 1)

(nlistp nil)

(stringp "a")

(stringp ?a)

(symbolp 'a)

(symbolp nil)

(symbolp :k)

(symbolp "a")

(vectorp [])

(vectorp "a")

(sequencep nil)

(sequencep "a")

(sequencep [1])

(sequencep '(1 . 2))

(sequencep 1)

(booleanp nil)

(booleanp t)

(booleanp 1)

(booleanp)

(characterp ?a)

(characterp 4194303)

(characterp 4194304)

(characterp -1)

(characterp 1.0)

(characterp 1180591620717411303424)

; naive: !! (wrong-number-of-arguments characterp 2)
(characterp 1 2)

(keywordp :a)

(keywordp 'a)

(keywordp ":a")

(keywordp nil)

(numberp 1)

(numberp 'a)

(integerp 1180591620717411303424)

(natnump 0)

(natnump -1)

(natnump 1.0)

(identity '(1 2))

(identity)

(ignore)

(ignore 1 2 3)

(functionp 'car)

(functionp 'funcall)

(functionp 'ignore)

(functionp 'when)

(functionp 'if)

(functionp 'setq)

(functionp 'lambda)

(functionp #'car)

(functionp '(lambda (x) x))

(functionp (lambda (x) x))

; naive: => t
(functionp '(closure (t) (x) x))

(functionp nil)

(functionp "car")

(functionp 1)

(functionp 'concat)

(functionp 'diary-date)

(functionp 'org-date)

(functionp 'zzz-organ-elisp-undefined)

(functionp t)

(functionp :k)
