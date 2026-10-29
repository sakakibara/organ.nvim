; profile: var
; mode: eval
; case_fold: nil
; condition-case, signal, error, user-error and their data, lexical binding.

(condition-case e (car 1) (error e))

(condition-case e (car 1) (wrong-type-argument (list 'w e)) (error 2))

(condition-case e (car 1) ((arith-error wrong-type-argument) (list 'm e)))

(condition-case e (car 1) ((debug wrong-type-argument) e))

(condition-case e (car 1) (t (list 't e)))

(condition-case e (car 1) (arith-error 1))

(condition-case nil (car 1) (error 5))

(condition-case e 1 (:success (list 's e)))

(condition-case e (car 1) (:success (list 's e)) (error (list 'f e)))

(condition-case nil 7 (:success 8))

; naive: => 8
(condition-case e 7 (:success 8) (:success 9))

(condition-case e (car 1) (error))

(condition-case e (car 1) (error . 3))

(condition-case e (car 1) nil (error e))

(condition-case e (car 1) (((error)) e) (t 3))

(condition-case e (car 1) ((1) e) (t 3))

(condition-case e (car 1) ((foo . error) e))

(condition-case nil 1 b)

(condition-case nil 1 (1 2))

(condition-case e (car 1) ("x" e))

(condition-case 1 1)

(condition-case)

(condition-case e)

(condition-case e (car 1) (error 2) . 3)

(condition-case e (car 1) (error (setq e 5) e))

(condition-case e 1 (:success (setq e 5) e))

(condition-case e (condition-case f (car 1) (arith-error 3)) (error (list 9 e)))

(condition-case e (condition-case f (car 1) (error (car 2))) (error (list 'outer e)))

(let ((e 1)) (condition-case e (car 1) (error 2)) e)

(let ((e 1)) (list (condition-case e (car 1) (error e)) e))

(condition-case e (car 1) (:success 1) (error (list e)))

(condition-case t (car 1) (error t))

(condition-case :k (car 1) (error :k))

(condition-case e (signal 'wrong-type-argument 5) (error e))

(condition-case e (error "boom") (error e))

(condition-case e (user-error "u") (error e))

(condition-case e (user-error "u") (user-error (list 'u e)))

(condition-case e (signal 'foo '(1)) (error e))

(condition-case e (signal 'overflow-error '(1)) (arith-error e))

(condition-case e (signal 'args-out-of-range '(1)) (arith-error 1) ((error) e))

(condition-case e (signal nil '(wrong-type-argument . 5)) (error e))

(condition-case e (signal nil 5) (error e))

(condition-case e (signal nil '(nil)) (error e))

(condition-case e (funcall #'car) (wrong-number-of-arguments 1))

(ignore-errors (car 1) 2)

(ignore-errors 1 2)

(ignore-errors)

(ignore-errors (car 1))

(ignore-errors . 1)

(signal 'error nil)

(signal 'error '("x" 1))

(signal 'error 5)

(signal nil nil)

; naive: !! (error Invalid error symbol nil)
(signal nil '(nil))

(signal nil 5)

(signal nil '(5))

(signal nil '(foo 1))

(signal nil '(wrong-type-argument . 5))

(signal 'foo nil)

(signal t nil)

(signal 1 nil)

(signal "x" nil)

(signal 'error)

(signal)

(signal 'error nil nil)

(signal 'void-variable '(x))

(signal 'args-out-of-range '(1 2))

(signal 'wrong-type-argument '(a . 5))

(signal 'error '("x" . 5))

(signal :k nil)

(signal 'end-of-file nil)

(signal 'user-error '("a" "b"))

(signal 'error '(1 2))

(error "boom")

(error "boom" 1 2)

(error "")

(error 'foo)

(error nil)

(error)

(error "x" . 1)

(error "%s" 1)

(error "it's")

(user-error "u")

(user-error "")

(user-error 'foo)

(user-error)

(error "a\nb")
