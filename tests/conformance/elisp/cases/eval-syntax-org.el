; profile: prefix
; mode: eval
; case_fold: nil
; Word finding under the org-mode syntax table: ', U+00B7, U+05F3, U+05F4 and U+2027 are word
; constituents.

; naive: => "It'S"
(capitalize "it's")

(upcase-initials "it's ok")

(capitalize "a·b")

(capitalize "x׳y")

(upcase-initials "x״y")

(capitalize "a‧b")

(capitalize ?')

(capitalize "rock'n'roll it·s")
