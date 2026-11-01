; profile: var
; mode: eval
; case_fold: nil
; Calendar functions under lexical binding and through closures.

(let ((d '(10 24 2026))) (calendar-day-of-week d))

(let ((d (list 2 29 2024))) (funcall (lambda () (calendar-date-is-valid-p d))))

(mapcar (lambda (y) (calendar-leap-year-p y)) '(1900 2000 2024 -1))

(let ((calendar-date-style 'european)) (calendar-extract-day '(10 24 2026)))

(calendar-gregorian-from-absolute (+ 7 (calendar-absolute-from-gregorian '(12 28 2026))))

(apply #'calendar-last-day-of-month '(2 2028))
