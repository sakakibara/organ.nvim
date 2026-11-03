; profile: prefix
; mode: eval
; case_fold: nil
; syntax_table: agenda
; Word finding under the syntax table of an org-agenda-mode buffer, current when Emacs formats
; time-grid lines and diary-file rows: ', U+00B7, U+05F3, U+05F4 and U+2027 are not word
; constituents there.

; naive: => "It's"
(capitalize "it's")

(upcase-initials "it's ok")

(capitalize "a·b")

(capitalize "x׳y")

(upcase-initials "x״y")

(capitalize "a‧b")

(capitalize ?')

(capitalize "rock'n'roll it·s")
