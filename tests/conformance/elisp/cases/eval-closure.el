; profile: table
; mode: eval
; case_fold: nil
; Closures created where a variable is bound lexically: Emacs macroexpands their body at creation; the same forms under dynamic binding.

(let ((x 1)) (funcall (lambda () (funcall #'car))))

(let ((x 1)) (funcall (lambda () (funcall #'car (car 1) 2))))

(let ((x 1)) (funcall (lambda () (funcall #'(lambda (y) (list y x)) 2))))

(let ((x 1)) (funcall (lambda () (funcall #'(lambda (&optional y &rest z) (list y z x)) 1 2 3))))

(let ((x 1)) (funcall (lambda () (funcall (lambda (y) y)))))

(let ((x 1)) (funcall (lambda () (funcall (lambda (y) (list x y)) 1 2))))

(let ((x 1)) (lambda () (dolist y)) 5)

(let ((x 1)) (lambda () (when)) 5)

(let ((x 1)) (lambda () `(\, a b)) 5)

(let ((x 1)) (lambda () (cond 1)) 5)

(progn (lambda () (dolist y)) 5)

(let ((x 1)) (lambda () (funcall #'(lambda (&rest) 1))) 5)

(let ((x 1)) (funcall (lambda () (condition-case 1 1))))

(let ((x 1)) (funcall (lambda () (list x `(a ,x ,@(list x))))))

(let ((x 1)) (funcall (lambda () (dolist (y '(1 2) x) (setq x (cons y x))))))

(let ((x 1)) (funcall (lambda () (dotimes (i 2 x) (setq x (cons i x))))))

(let ((x 1)) (funcall (lambda () (when x (unless nil (prog2 1 x 3)))))) 

(let ((x 1)) (funcall (lambda () (ignore-errors (car x)))))

(let ((x 1)) (funcall (lambda () (condition-case e (car x) (error (list e x))))))

(let ((x 1)) (funcall (lambda () (let* ((y x) (z (cons y y))) z))))

(let ((x 1)) (funcall (lambda () (funcall #'funcall #'car))))

(let ((x 1)) (funcall (lambda () (funcall 'car))))

(let ((x 1)) (funcall (lambda (&optional y) (list x y))))

(let ((x 1)) (funcall (lambda () (funcall (lambda (fill-column) fill-column) 2))))

(let ((x 1)) (funcall (lambda () (funcall #'(lambda (y) "doc" y) 3))))

(let ((x 1)) (funcall (lambda () ((lambda (y) (list x y)) 2))))

(let ((x 1)) (funcall (lambda () (funcall #'(lambda () "only")))))

(let ((x 1)) (funcall (lambda () (setq x 2) x)))

(let ((x 1)) (funcall (lambda () (funcall #'(lambda (&rest r) r) 1 2))))

(let ((x 1)) (funcall (lambda () (funcall #'(lambda (&rest r) r)))))

(let ((x 1)) (funcall (lambda () (while nil) (cond (nil 1) (x 2)))))

(let ((x 1)) (funcall (lambda () (funcall #'identity x 2))))

(let ((x 1)) (funcall (lambda () (identity x 2))))

(let ((x 1)) (lambda () (foo)) 5)

(let ((x 1)) (lambda () (funcall #'foo)) 5)

(let ((x 1)) (lambda (&optional) x) 5)
