; profile: diary
; mode: eval
; case_fold: nil
; date: (10 24 2026)
; entry: Ent %d%s
; Diary sexp functions as diary-lib.el and org-agenda.el define them: arguments in
; calendar-date-style order (american unless bound), `date' and `entry' read
; dynamically, anniversaries and cycles formatting the entry.

(diary-date 10 24 2026)

(diary-date 10 24 t)

(diary-date t t t)

(diary-date 10 24 2026 'mark)

(diary-date '(9 10) 24 2026)

(diary-date 10 '(23 24 . 25) 2026)

(diary-date 10 '(23 . 25) 2026)

; naive: => (nil . "Ent %d%s")
(diary-date 10.0 24 2026)

(diary-date 24 10 2026)

(diary-date 10 25 2026)

(let ((calendar-date-style 'european)) (diary-date 24 10 2026))

(let ((calendar-date-style 'iso)) (diary-date 2026 10 24))

(let ((calendar-date-style 'bogus)) (diary-date 10 24 2026))

(let ((entry nil)) (diary-date 10 24 2026))

(let ((date '(10 24 . 2026))) (diary-date 10 24 2026))

(let ((date 5)) (diary-date 10 24 2026))

(diary-block 10 1 2026 10 31 2026)

(diary-block 10 24 2026 10 24 2026)

(diary-block 10 25 2026 10 31 2026)

(diary-block 10 1 2026 2 30 2027 "*")

(diary-block 1 1 0 1 1 2026)

(let ((calendar-date-style 'european)) (diary-block 1 10 2026 31 10 2026))

(diary-cyclic 7 10 3 2026)

(diary-cyclic 1 10 24 2026)

(diary-cyclic 7 10 4 2026)

(diary-cyclic 7 10 31 2026)

(diary-cyclic 0 10 3 2026)

(diary-cyclic -7 10 3 2026)

(diary-cyclic 7.0 10 3 2026)

(diary-cyclic 1 1 1 1)

(diary-anniversary 10 24 2000)

(diary-anniversary 10 24)

(diary-anniversary 10 24 2026)

(diary-anniversary 10 24 2030)

; naive: => (nil . "Ent 11st")
(diary-anniversary 10 24 2015)

(diary-anniversary 10 24 2005)

(diary-anniversary 10 24 2004)

(diary-anniversary 10 24 2003)

; naive: => (nil . "Ent 112nd")
(diary-anniversary 10 24 1914)

; naive: => nil
(let ((date '(3 1 2026))) (diary-anniversary 2 29 2024))

(let ((date '(2 28 2026))) (diary-anniversary 2 29 2024))

(let ((date '(2 29 2028))) (diary-anniversary 2 29 2024))

(let ((entry "100%")) (diary-anniversary 10 24 2000))

(let ((entry "%s years")) (diary-anniversary 10 24 2000))

(let ((entry 5)) (diary-anniversary 10 24 2000))

(let ((calendar-date-style 'iso)) (diary-anniversary 2000 10 24))

(diary-float 10 6 4)

; naive: => nil
(diary-float 10 6 -2)

(diary-float 10 6 -1)

(diary-float t 6 4)

(diary-float '(9 10) 6 4)

(diary-float '(9 11) 6 4)

; naive: => nil
(diary-float 10 6 1 20)

(diary-float 10 6 -1 27)

(diary-float 10 6 -1 23)

(diary-float 10 5 4)

(diary-float 10 6 0)

; naive: => nil
(let ((date '(11 1 2025))) (diary-float 10 6 1 30))

(let ((date '(11 1 2025))) (diary-float 11 6 1))

(let ((date '(9 27 2025))) (diary-float 10 6 -1 3))

(diary-float 10 "6" 4)

(diary-float 10 6 'x)

(org-date 2026 10 24)

(org-date t 10 t)

(org-date 10 24 2026)

(org-block 2026 10 1 2026 10 31)

(org-cyclic 7 2026 10 3)

(org-anniversary 2000 10 24)

(let ((calendar-date-style 'european)) (org-date 2026 10 24))

(org-class 2026 9 1 2026 12 31 6)

(org-class 2026 9 1 2026 12 31 6 43)

(org-class 2026 9 1 2026 12 31 6 42 44)

(org-class 2026 9 1 2026 12 31 5)

(org-class 2026 9 1 2026 10 23 6)

(org-class 2026 9 1 2026 12 31 6.0)

(org-class 2026 9 1 2026 12 31 6 'holidays)

(org-class 2026 9 1 2026 12 31 6 "Halloween")

(org-class 2026 9 1)
