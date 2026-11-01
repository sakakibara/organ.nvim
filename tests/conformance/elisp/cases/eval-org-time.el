; profile: var
; mode: eval
; case_fold: nil
; org-time-string-to-time and org-time-stamp-format as org 9.8.7 defines them; the custom formats are a user setting and refuse.

(org-time-string-to-time "2024-01-15")

(org-time-string-to-time "<2024-01-15 Mon>")

(org-time-string-to-time "<2024-01-15 Mon 10:30>")

(org-time-string-to-time "[2024-01-15 Mon 9:05]")

(org-time-string-to-time "2024-01-15 10:30")

(org-time-string-to-time "2024-01-15  Mon  10:30")

(org-time-string-to-time "2024-01-15 Mon 123:45")

(org-time-string-to-time "2024-01-15 Mon 1:3")

(org-time-string-to-time "2024-01-15 lundi 10:30")

(org-time-string-to-time "2024-01-15 月 10:30")

(org-time-string-to-time "2024-01-15 +1w 10:30")

(org-time-string-to-time "2024-13-45")

(org-time-string-to-time "0000-01-01")

(org-time-string-to-time "x12024-01-15")

(org-time-string-to-time "-52000-02-03")

(org-time-string-to-time "<%%(diary-float t 4 2)>")

(org-time-string-to-time "2024-1-15")

(org-time-string-to-time "")

(org-time-string-to-time 'x)

(org-time-string-to-time)

(org-time-string-to-time "2024-01-15" 1)

(org-time-string-to-time "2024-03-10 02:30")

(org-time-stamp-format)

(org-time-stamp-format t)

(org-time-stamp-format nil t)

(org-time-stamp-format t t)

(org-time-stamp-format nil 'no-brackets)

(org-time-stamp-format t 'keep-format)

(org-time-stamp-format nil 'inactive)

(eq (org-time-stamp-format nil 'keep-format) (org-time-stamp-format nil 'no-brackets))

(org-time-stamp-format nil nil t)

(org-time-stamp-format 1 2 3 4)
