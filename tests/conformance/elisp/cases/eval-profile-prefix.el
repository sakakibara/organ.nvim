; profile: prefix
; mode: eval
; case_fold: nil
; date: (10 24 2026)
; The prefix profile: date is a dynamic global; a let of it binds lexically.

date

(let ((date 5)) (funcall '(lambda () date)))

(let ((date 5)) date)

(funcall (lambda (date) date) 6)

(org-date 1 2 3)

(diary-date 1 2 3)
