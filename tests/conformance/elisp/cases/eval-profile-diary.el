; profile: diary
; mode: eval
; case_fold: nil
; date: (10 24 2026)
; entry: Meeting
; The diary profile binds date and entry dynamically.

date

entry

(list date entry)

(let ((date 1)) date)

(funcall '(lambda () date))

(let ((f (lambda () date))) (let ((date 2)) (funcall f)))

(org-date 1 2 3)
