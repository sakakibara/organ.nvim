; profile: table
; mode: eval
; case_fold: nil
; Calendar functions as calendar.el defines and compiles them: absolute days from the
; imaginary 12/31/1 BC, negative years as BC with no year zero, no date validation in
; the arithmetic, and `nth' and `cadr' run as byte-code.

(calendar-day-of-week '(10 24 2026))

(calendar-day-of-week '(1 1 1))

(calendar-day-of-week '(12 31 -1))

(calendar-day-of-week '(1 1 1.5))

(calendar-absolute-from-gregorian '(1 1 1))

(calendar-absolute-from-gregorian '(10 24 2026))

(calendar-absolute-from-gregorian '(12 31 -1))

(calendar-absolute-from-gregorian '(1 1 -1))

(calendar-absolute-from-gregorian '(3 1 -5))

; naive: => 0
(calendar-absolute-from-gregorian '(1 1 0))

(calendar-absolute-from-gregorian '(2 30 2026))

(calendar-absolute-from-gregorian '(13 40 2026))

(calendar-absolute-from-gregorian '(0 0 2026))

(calendar-absolute-from-gregorian '(1 1.5 2026))

(calendar-absolute-from-gregorian '(2 1 2000.0))

(calendar-absolute-from-gregorian '(3 1 2000.0))

(calendar-absolute-from-gregorian (list 3 1 (expt 10 30)))

(calendar-absolute-from-gregorian (list 3 1 (- (expt 10 30))))

(calendar-absolute-from-gregorian '(1 2 . 3))

(calendar-absolute-from-gregorian '(1 2))

(calendar-absolute-from-gregorian '("1" 2 2026))

(calendar-absolute-from-gregorian 5)

(calendar-absolute-from-gregorian nil)

(calendar-gregorian-from-absolute 1)

(calendar-gregorian-from-absolute 739913)

(calendar-gregorian-from-absolute 730485)

(calendar-gregorian-from-absolute 146097)

; naive: => (12 31 -1)
(calendar-gregorian-from-absolute 0)

(calendar-gregorian-from-absolute -1)

(calendar-gregorian-from-absolute -146097)

(calendar-gregorian-from-absolute 1.5)

(calendar-gregorian-from-absolute (expt 10 20))

(calendar-gregorian-from-absolute nil)

(calendar-gregorian-from-absolute (calendar-absolute-from-gregorian '(2 29 2024)))

(calendar-extract-month '(10 24 2026))

(calendar-extract-day '(10 24 2026))

(calendar-extract-year '(10 24 2026))

(calendar-extract-year '(10 24))

(calendar-extract-year '(1 . 2))

; naive: !! (wrong-type-argument listp (1 2 . 3))
(calendar-extract-year '(1 2 . 3))

(calendar-extract-day '(1 . 2))

(calendar-extract-day 5)

(calendar-extract-month [10 24 2026])

(calendar-leap-year-p 2000)

(calendar-leap-year-p 1900)

(calendar-leap-year-p 2024)

(calendar-leap-year-p 2026)

; naive: => nil
(calendar-leap-year-p -1)

(calendar-leap-year-p -5)

(calendar-leap-year-p 0)

(calendar-leap-year-p (expt 10 30))

(calendar-leap-year-p 2024.0)

(calendar-leap-year-p nil)

(calendar-last-day-of-month 2 2024)

(calendar-last-day-of-month 2 1900)

(calendar-last-day-of-month 12 2026)

(calendar-last-day-of-month 13 2026)

(calendar-last-day-of-month 0 2026)

(calendar-last-day-of-month 1.0 2026)

(calendar-last-day-of-month 2 2024.0)

(calendar-day-number '(12 31 1980))

(calendar-day-number '(3 1 2024))

(calendar-day-number '(2 30 2026))

(calendar-day-number '(14 1 2026))

(calendar-day-number '(3 1.5 2026))

(calendar-date-is-valid-p '(2 29 2024))

(calendar-date-is-valid-p '(2 29 2023))

(calendar-date-is-valid-p '(12 31 9999))

(calendar-date-is-valid-p '(1 1 0))

(calendar-date-is-valid-p '(1 1 -1))

(calendar-date-is-valid-p '(13 1 2026))

; naive: => nil
(calendar-date-is-valid-p '(1 1 2026 . 5))

(calendar-date-is-valid-p '(1 1 2026 5))

(calendar-date-is-valid-p '(1 1))

(calendar-date-is-valid-p "abc")

(calendar-date-is-valid-p [1 1 2026])

(calendar-date-is-valid-p '(1.0 1 2026))

(calendar-date-is-valid-p (list 1 1 (expt 10 30)))

(calendar-day-of-week)

(funcall #'calendar-last-day-of-month 2)

(mapcar #'calendar-day-of-week '((1 1 2026) (1 2 2026)))
