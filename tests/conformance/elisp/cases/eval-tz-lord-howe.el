; profile: table
; mode: eval
; case_fold: nil
; tz: Australia/Lord_Howe
; Local time in Australia/Lord_Howe, whose DST moves the clock half an hour.

(decode-time 0)

(decode-time 1700000000)

(decode-time 1720000000)

(decode-time 1700000000 'wall)

(format-time-string "%F %T %Z %z" 1700000000)

(format-time-string "%F %T %Z %z" 1720000000)

(format-time-string "%F %T %Z %z %s" 1710054000)

(format-time-string "%F %T %Z %z %s" 1730613000)

(format-time-string "%F %T %Z %z" -2208988800)

(format-time-string "%F %T %Z %z" 4118000000)

(encode-time '(0 0 0 1 1 2024))

(encode-time '(0 0 0 1 7 2024))

(encode-time '(0 30 2 10 3 2024))

(encode-time '(0 30 1 3 11 2024 nil t nil))

(encode-time '(0 30 1 3 11 2024 nil nil nil))

(encode-time '(0 0 2 7 4 2024 nil -1 nil))

(encode-time '(0 15 2 6 10 2024 nil -1 nil))

(encode-time '(0 0 0 1 1 1950 nil -1 nil))

(encode-time '(0 0 0 1 7 2200 nil -1 nil))

(encode-time '(0 0 0 1 1 2024 nil t nil))

(org-time-string-to-time "<2024-03-10 Sun 02:30>")

(org-time-string-to-time "<2024-07-01 Mon 12:00>")

(decode-time (org-time-string-to-time "2024-10-06 02:15"))

(encode-time '(0 45 1 7 4 2024 nil t nil))

(encode-time '(0 45 1 7 4 2024 nil nil nil))
