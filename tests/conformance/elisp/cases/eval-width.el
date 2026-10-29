; profile: table
; mode: eval
; case_fold: nil
; Display widths: string-width, format width and precision, truncate-string-to-width and string-pad; a character whose width differs between users refuses.

(string-width "abc")

(string-width "字a")

(string-width "a\nb")

(string-width "a\tb")

(string-width "é")

(string-width "é")

(string-width "é§")

(string-width "🙂")

(string-width "abc" 1)

(string-width "abc" 1 -1)

(string-width "abc" 4)

(string-width 'a)

(format "%5s|%-5s|%.3s|%.2s" "字" "字" "字字" "字字")

(format "%5.2s|%-5.1s|%05s" "abcdef" "xyz" "ab")

(format "%5s" "a\tb")

(format "%s|" "a\tb")

(format "%.1s|" "a\tb")

(format "%3s|" "é")

(format "%3s|" "é")

(truncate-string-to-width "abcdef" 4)

(truncate-string-to-width "abcdef" 4 nil nil "..")

(truncate-string-to-width "abcdef" 4 nil nil "...")

; naive: => "d..."
(truncate-string-to-width "abcdef" 4 3 nil "...")

(truncate-string-to-width "abcdef" 4 3 ?x "...")

(truncate-string-to-width "ab字cd" 3 nil ?-)

(truncate-string-to-width "ab字cd" 4 3 ?-)

(truncate-string-to-width "abc" 10 5 ?-)

(truncate-string-to-width "abc" 10 5)

(truncate-string-to-width "abcdef" 2.5)

(truncate-string-to-width "abc" "x")

(truncate-string-to-width 5 2)

(truncate-string-to-width '(97) 2)

(truncate-string-to-width "abc" -1)

(truncate-string-to-width "abc" 5 nil ?x)

(truncate-string-to-width "abc" 5 nil "x")

(truncate-string-to-width "abcdef" 4 nil nil t)

(truncate-string-to-width "abcdef" 4 nil nil "..." t)

(truncate-string-to-width "a\tb" 2)

(let ((s "abc")) (eq s (truncate-string-to-width s 5)))

(string-pad "abc" 5)

(string-pad "abc" 5 ?- t)

; naive: => "字 "
(string-pad "字" 3)

(string-pad "abc" 2)

(string-pad "abc" -1)

(string-pad "abc" 1.0)

(string-pad '(?a) 3)

(string-pad "a" 3 "x")

(string-pad "abc" 1180591620717411303424)

(let ((s "abc")) (eq s (string-pad s 2)))
