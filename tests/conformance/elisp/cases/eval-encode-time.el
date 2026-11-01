; profile: table
; mode: eval
; case_fold: nil
; encode-time: the list and obsolescent calling conventions, field normalization and limits, the DST flag in each kind of zone, gaps and overlaps, sub-second forms and argument errors.

(encode-time '(0 0 0 1 1 2024))

(encode-time '(0 0 0 1 1 2024 nil nil t))

(encode-time '(0 0 0 1 1 2024 nil -1 t))

(encode-time '(0 0 0 1 1 2024 nil t t))

(encode-time '(0 0 0 1 1 2024 nil nil 3600))

(encode-time '(0 0 0 1 1 2024 nil t 3600))

(encode-time '(0 0 0 1 1 2024 nil nil (3600 "ABC")))

(encode-time '(0 0 0 1 1 2024 nil nil "America/New_York"))

(encode-time '(0 0 0 1 7 2024 nil nil "America/New_York"))

(encode-time '(0 0 0 1 7 2024 nil -1 "America/New_York"))

(encode-time '(0 0 12 15 1 2024 nil t "America/New_York"))

; naive: => (26093 21352)
(encode-time '(0 30 2 10 3 2024 nil -1 "America/New_York"))

(encode-time '(0 30 2 10 3 2024 nil t "America/New_York"))

(encode-time '(0 30 2 10 3 2024 nil nil "America/New_York"))

(encode-time '(0 30 1 3 11 2024 nil t "America/New_York"))

(encode-time '(0 30 1 3 11 2024 nil nil "America/New_York"))

; naive: => (26093 23183)
(encode-time '(75 59 1 10 3 2024 nil -1 "America/New_York"))

(encode-time '(0 0 0 1 1 2024 nil nil "Asia/Kolkata"))

(encode-time '(0 0 0 1 13 2023 nil nil t))

(encode-time '(0 0 0 0 1 2024 nil nil t))

(encode-time '(-1 0 0 1 1 2024 nil nil t))

(encode-time '(3600 -60 25 31 -13 2024 nil nil t))

(encode-time '(61 59 23 31 12 2023 nil nil t))

(encode-time '(0 0 0 1 1 0 nil nil t))

(encode-time '(0 0 0 1 1 -5000 nil nil t))

(encode-time '(0 0 0 1 1 2147485547 nil nil t))

(encode-time '(0 0 0 1 13 2147485547 nil nil t))

(encode-time '(0 0 0 1 1 2147485548 nil nil t))

(encode-time '(2147483647 0 0 1 1 2024 nil nil t))

(encode-time '(2147483648 0 0 1 1 2024 nil nil t))

(encode-time (list (expt 2 62) 0 0 1 1 2024 nil nil t))

(encode-time '(1.5 0 0 1 1 2024 nil nil t))

(encode-time '(0 1.5 0 1 1 2024 nil nil t))

(encode-time '((3 . 2) 0 0 1 1 2024 nil nil t))

(encode-time '((1 2 3 4) 0 0 1 1 2024 nil nil t))

(encode-time '((-1 . 4) 0 0 1 1 2024 nil nil t))

(encode-time (list (cons 1 (expt 2 70)) 0 0 1 1 2024 nil nil t))

(let ((h (expt 2 70))) (eq (cdr (encode-time (list (cons 0 h) 0 0 1 1 2024 nil nil t))) h))

(encode-time '(1 2 3))

(encode-time '(1 2 3 4 5 6 7))

(encode-time '(1 2 3 4 5 6 7 8))

(encode-time '(0 0 0 1 1 2024 nil nil t extra))

(encode-time '(1 2 3 4 5 . 6))

(encode-time nil)

(encode-time 5)

(encode-time 0 0 0 1 1 2024)

(encode-time 0 0 0 1 1 2024 t)

(encode-time 0 0 0 1 1 2024 nil nil t)

(encode-time 0 0 0 1 1 2024 'ignored t)

(encode-time 0 0 0 1 1 2024 nil 3600)

(encode-time 1 2)

(encode-time 1 2 3 4 5)

(encode-time 1 (error "first"))

(encode-time)

(apply #'encode-time '(1 2))

(funcall #'encode-time)

(encode-time '(0 0 0 1 1 2024 nil nil foo))

(encode-time '(0 0 0 1 1 2024 nil nil "garbage"))
