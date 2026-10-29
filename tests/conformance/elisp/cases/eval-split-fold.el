; profile: table
; mode: eval
; case_fold: t
; split-string and string-trim under case-fold-search t: literal regexps fold ASCII case; a non-ASCII cased letter in one refuses.

(split-string "aKbkc" "k")

(split-string "aſbSc" "s")

(split-string "aİbIcıd" "i")

(split-string "aÉbéc" "é")

(split-string "a1b" "1")

(string-trim "XaX" "x" "x")

(string-trim-left "ABab" "ab")

(string-trim-right "abAB" "ab")

(split-string "Ab,aB" "," nil "a")

(let ((case-fold-search nil)) (split-string "aKbkc" "k"))
