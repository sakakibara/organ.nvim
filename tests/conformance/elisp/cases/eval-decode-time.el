; profile: table
; mode: eval
; case_fold: nil
; decode-time: every zone form, the SEC forms FORM selects, the range limits, and the zones whose rules organ does not reproduce.

(decode-time 0 t)

(decode-time 1700000000 t)

(decode-time 1700000000)

(decode-time 1700000000 "America/New_York")

(decode-time 1720000000 "America/New_York")

(decode-time 1720000000 "Australia/Lord_Howe")

(decode-time 1700000000 "Australia/Lord_Howe")

(decode-time 1700000000 "Europe/Dublin")

(decode-time 1720000000 "Europe/Dublin")

(decode-time 0 3600)

(decode-time 0 -12600)

(decode-time 0 '(19800 "IST"))

(decode-time 0 0)

(decode-time 1.25 t t)

(decode-time 1.25 t)

(decode-time 1.25 t 'integer)

(decode-time '(1 2 3 4) t t)

(decode-time '(7 . 4) t t)

(decode-time '(-7 . 4) t t)

(decode-time '(1 2 "x" y) t)

(decode-time '(1 2 "x" y) t t)

(decode-time -1 t)

(decode-time -62135596800 t)

(decode-time -62135596801 t)

(decode-time 253402300800 t)

(decode-time -2208988800 "America/New_York")

(decode-time -5000000000 "Asia/Tokyo")

(decode-time 4102444800 "America/New_York")

(decode-time 4118000000 "America/New_York")

(decode-time 67768036191676799 t)

(decode-time 67768036191676800 t)

(decode-time -67768040609740800 t)

(decode-time (expt 2 70) t)

(decode-time '(1 . 0) t)

(decode-time 0 'x)

(decode-time 15552000 "XST5XDT,M3.2.0,M11.1.0")

(decode-time -315619200 "XST5XDT,M3.2.0,M11.1.0")

(decode-time 0 "garbage")

(decode-time 1 2 3 4)
