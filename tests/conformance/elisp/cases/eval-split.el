; profile: table
; mode: eval
; case_fold: nil
; split-string and string-trim with the default regexps and literal ones, case-sensitive; any other regexp refuses.

(split-string "  two words ")

(split-string "  two words " " ")

(split-string "  two words " " " t)

(split-string "a,b,,c" ",")

(split-string "a,b,,c" "," t)

(split-string "a,b,,c" "," nil " ")

(split-string " a , b ,, c " "," t " ")

; naive: => ("a" "b" "c")
(split-string "abc" "")

(split-string "abc" "" t)

(split-string "xxaxx" "y" nil "x")

(split-string "" ",")

(split-string "")

(split-string "a\fb\vc d")

(split-string "aKbkc" "k")

(split-string "aÉbéc" "é")

(split-string "a::b" "::")

(split-string "a b" "[ ]+")

(split-string "a.b" ".")

(split-string 5)

(split-string "a" 5)

(split-string '(1) "x")

(split-string "a b" nil nil 5)

(split-string "a b" nil nil '(?a))

(let ((s "abc")) (eq s (car (split-string s))))

(let ((s "abc")) (eq s (car (split-string s "," nil "x"))))

(string-trim "  a  ")

; naive: => "a"
(string-trim "xxaxx" "x" "x")

(string-trim "aaa" "a" "a")

(string-trim "a" "a" "a")

(string-trim "")

(string-trim "  ")

(string-trim "\f a \f")

(string-trim "XaX" "x" "x")

(string-trim "a" "" "")

(string-trim-left "aab" "a")

(string-trim-right "baa" "a")

(string-trim-left "  a  ")

(string-trim-right "  a  ")

(string-trim-left "a" "")

(string-trim 5)

(string-trim "a" 5)

(string-trim-left 5 "[")

(string-trim "a b" "[ ]+")

(let ((s "abc")) (eq s (string-trim s)))

(let ((s "abc")) (eq s (string-trim-left s)))

(let ((s "abc")) (eq s (string-trim-right s)))

(let ((s " abc")) (eq s (string-trim s)))
