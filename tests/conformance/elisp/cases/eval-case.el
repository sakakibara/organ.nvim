; profile: table
; mode: eval
; case_fold: nil
; Case conversion: the character case table, Unicode special casing for strings, words under the org-mode syntax table, modifier bits and the final-sigma context.

; naive: => "ABC É ß"
(upcase "abc é ß")

; naive: => 223
(upcase ?ß)

(downcase "ÀB")

(upcase "ﬁ")

(upcase ?ﬁ)

(downcase "İ")

(downcase ?İ)

(capitalize "ǆemal ŉ ﬁsh")

(upcase-initials "ǆemal ﬁsh ab-cd")

; naive: => "Foo-bar Baz_qux 1st X'Y"
(capitalize "foo-bar baz_qux 1st x'y")

(upcase-initials "hELLO wORLD")

(capitalize "hELLO wORLD")

(capitalize "ⓐⓑ")

(downcase "ΣΑ")

(downcase "ΑΣ")

(capitalize "ΣΑΣ")

(upcase "σας")

(capitalize ?ǆ)

(upcase-initials ?ǆ)

(downcase ?A)

(upcase (+ ?a 134217728))

(upcase 268435457)

(upcase 264241152)

; naive: => 4294967393
(upcase (+ 97 (ash 1 32)))

(upcase 2305843009213693951)

(upcase 2305843009213693952)

(upcase #x200200)

(upcase -1)

(upcase 1.0)

(upcase 'a)

(upcase)

(capitalize "")

(let ((s "")) (eq s (upcase s)))
