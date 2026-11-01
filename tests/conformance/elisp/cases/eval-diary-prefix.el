; profile: prefix
; mode: eval
; case_fold: nil
; date: (10 24 2026)
; entry: Ent
; The prefix profile has org-agenda's diary wrappers and org-class, without
; diary-lib: the wrappers refuse where they call into it, as does org-class where it
; checks holidays.

(org-class 2026 9 1 2026 12 31 6)

(org-class 2026 9 1 2026 12 31 5)

(org-class 2026 9 1 2026 12 31 6 43)

(let ((date '(10 23 2026))) (org-class 2026 9 1 2026 12 31 6))

(funcall '(lambda (date) (org-class 2026 9 1 2026 12 31 5)) '(10 23 2026))

(org-date 2026 10 24)

(org-anniversary 2000 10 24)

(org-block 2026 10 1 2026 10 31)

(org-cyclic 7 2026 10 3)

(org-date 2026 10)

(org-date (car 1) 10 24)

(calendar-day-of-week date)

(let ((calendar-date-style 'iso)) (calendar-extract-day date))
