; profile: capture
; mode: eval
; case_fold: nil
; Strings under lexical binding: closures (string> rewritten by its compiler macro), mapconcat and string-join calling functions, case-fold-search bound around a search.

(let ((x 1)) (funcall (lambda (a b) (string> a b)) "b" "a"))

(let ((x 1)) (funcall (lambda () (string> 1 2))))

(let ((x 1)) (funcall (lambda () (string-greaterp 'a 'b))))

(let ((x 1)) (funcall (lambda () (string> "a"))))

(string> "a")

(mapconcat (lambda (c) (string (upcase c))) "abc" "-")

(let ((sep ",")) (mapconcat (lambda (x) (format "%d" x)) '(1 2 3) sep))

(mapconcat (lambda (x) x) ["a" "b"] [?+])

(mapconcat #'symbol-name '(a b))

; naive: => "abc"
(mapconcat #'identity "abc")

(mapconcat #'identity '("a" "b") 5)

(mapconcat #'identity '("a" "b") '(?, ?\s))

(mapconcat 'foo nil 5)

(mapconcat #'identity '("a" . "b"))

(mapconcat #'identity [("a") "b"])

(mapconcat #'car '((1 2)))

(mapconcat #'identity '(nil "a"))

(mapconcat #'1+ '(1) "")

(mapconcat #'car '(1))

(mapconcat #'identity 5)

(string-join (list "a" "b") ", ")

(string-join '("a" (?b) [?c]) '(?-))

(string-join nil)

(string-join '("a") 5)

(string-join '("a" "b") 5)

(let ((s "abc")) (eq s (string-join (list s))))

(let ((case-fold-search t)) (split-string "aKbkc" "k"))

(let ((x "b")) (funcall (lambda () (string-prefix-p x "abc"))))
