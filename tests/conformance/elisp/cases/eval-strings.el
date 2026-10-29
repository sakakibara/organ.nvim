; profile: table
; mode: eval
; case_fold: nil
; Strings: building, measuring, indexing, comparing and searching, with Emacs's error data and object identity.

(concat "a" '(?b) [?c] nil "é")

(concat)

; naive: !! (wrong-type-argument listp (97 . 2))
(concat '(?a . 2))

(concat '(1000000000))

(concat 1)

(concat '(-1))

(length (concat "a" '(#x110000)))

(substring "héllo" 1 -1)

(substring "abc" -4)

(substring "abc" 2 1)

(substring "abc" 1.0)

(substring [1 2 3] 1)

(substring '(1 2) 1)

(substring "abc" nil 2)

(substring "abc")

(substring "abc" 2305843009213693951)

(substring "abc" 2305843009213693952)

(string-to-char "")

(string-to-char "éa")

(string-to-char 'a)

(char-to-string ?é)

(char-to-string -1)

(length (char-to-string #xD800))

(string ?a 300 ?字)

(string)

(string ?a 'b)

(make-string 3 ?é)

(make-string 0 ?a)

(make-string -1 ?a)

(make-string 2 -1)

(make-string 2 ?a t)

(make-string 1.0 ?a)

(string-to-list "aé")

(string-to-list [1 2])

(string-to-list '(1 . 2))

(string-to-list 5)

(string-to-vector "aé")

(string-to-vector '(1 2))

(string-to-vector '(1 . 2))

(length "aé字")

; naive: !! (wrong-type-argument listp (1 2 . 3))
(length '(1 2 . 3))

(length 5)

(length [1 2])

(length nil)

(length (lambda (x) x))

(symbol-name 'abc)

(symbol-name nil)

(symbol-name :k)

(symbol-name "a")

(intern "abc")

(intern "")

(intern "nil")

(intern ":k")

(intern 'a)

(intern "x" 1)

(intern 1 2)

(eq (intern "abc") 'abc)

(eq (symbol-name 'abc) (symbol-name 'abc))

(let ((s "abc")) (eq s (symbol-name (intern s))))

(string= "abc" "abc")

(string= 'abc "abc")

(string-equal "a" 1)

(string= 1 "a")

(string= "a")

(string< "abc" "abd")

(string< "é" "z")

(string< 'a "b")

(string-lessp "a" "a")

(string< "" "a")

(string> "b" "a")

(string-greaterp 'b 'a)

; naive: !! (wrong-type-argument stringp 1)
(string> 1 2)

(string> "a")

(string-prefix-p "ab" "abc")

(string-prefix-p "ABC" "abcd" t)

(string-prefix-p "abcd" "ab")

(string-prefix-p "a" 5)

(string-prefix-p "" nil)

(string-prefix-p '(1) "abc")

(string-prefix-p 'a "abc")

(string-suffix-p "bc" "abc")

(string-suffix-p "ÉE" "xée" t)

(string-suffix-p "a" 5)

(string-suffix-p "abcd" "bcd")

(string-search "b" "abc")

(string-search "" "abc" 3)

(string-search "" "abc" 4)

(string-search "b" "abc" -1)

(string-search "b" "abc" 1.0)

(string-search "é" "aéb")

(string-search "b" "aéb" 2)

(string-search "aab" "aaaab")

(string-search "B" "abc")

; naive: => 1
(let ((case-fold-search t)) (string-search "B" "abc"))

(string-search 1 "a")

(string-replace "a" "xy" "banana")

(string-replace "aa" "b" "aaaaa")

(string-replace "" "x" "abc")

(string-replace "a" "x" 5)

(string-replace 1 "x" "abc")

(string-replace "a" 1 "abc")

(string-replace "a" 1 "bcd")

(string-replace "a" '(?x) "abc")

(let ((s "abc")) (eq s (string-replace "x" "y" s)))

(string-empty-p "")

(string-empty-p 'a)

(string-empty-p nil)

(string-empty-p 1)

(string-blank-p " \t\n\r")

(string-blank-p "")

; naive: => 0
(string-blank-p "\f")

(string-blank-p 1)

(let ((s "abc")) (eq s (format "%s" s)))

(let ((s "abc")) (eq s (format s)))

(eq (symbol-name 'abc) (format "%s" 'abc))

(let ((s "abc")) (eq s (concat s)))

(let ((s "abc")) (eq s (substring s)))
