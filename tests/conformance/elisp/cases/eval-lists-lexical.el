; profile: capture
; mode: eval
; case_fold: nil
; Lists under lexical binding: the cXXr compiler macros inside closures, closures as list elements, and identity.

(let ((x '((1 2) 3))) (funcall (lambda () (list (caar x) (cadr x) (cdar x) (cddr x)))))

(let ((x 1)) (funcall (lambda () (cadr 1))))

(let ((x 1)) (funcall (lambda () (cadr))))

(let ((x 1)) (funcall (lambda () (cadr '(1 2) 3))))

(let ((f (lambda (x) x))) (list (length (list f f)) (eq (car (list f)) f) (eq (nth 1 (list 1 f)) f)))

(let ((f (lambda (x) x))) (length (memq f (list 1 f 2))))

(let ((f (lambda (x) x))) (eq (car (memq f (list 1 f))) f))

(let ((f (lambda (x) x)) (g (lambda (x) x))) (member f (list g)))

(let ((f (lambda (x) x))) (eq (car (append (list f) nil)) f))

(let ((f (lambda (x) x))) (eq (aref (vconcat (list f)) 0) f))

(let ((f (lambda (x) x))) (append f nil))

(let ((f (lambda (x) x))) (aref f 0))

(let ((f (lambda (x) x))) (elt f 0))

(let ((f (lambda (x) x))) (reverse f))

(let ((l (list 1 2 3))) (list (eq (nthcdr 1 l) (cdr l)) (eq (last l) (cddr l)) (eq (car (memq 2 l)) 2)))

(let ((s "abc")) (memq s (list "abc")))

(let ((s "abc")) (memq s (list "x" s)))

(memq 1.5 (list 1.5))

(memql 1.5 (list 1.5))

(memq 2305843009213693951 '(2305843009213693951))

(memq 2305843009213693952 '(2305843009213693952))
