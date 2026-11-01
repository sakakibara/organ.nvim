; profile: table
; mode: eval
; case_fold: nil
; format-time-string: every directive, flag, width and colon form under the C locale, zones of every kind, and its errors; the locale's names and formats and the UTC abbreviation refuse.

(format-time-string "%Y-%m-%d %H:%M:%S" 1700000000)

(format-time-string "%Y-%m-%d %H:%M:%S" 1700000000 t)

(format-time-string "%F %T %z" 1700000000 "America/New_York")

(format-time-string "%F %T %z %Z" 1720000000 "America/New_York")

(format-time-string "%F %T %Z %z" 1700000000 "UTC")

(format-time-string "%F %T %Z %z" 1700000000 "Asia/Tokyo")

(format-time-string "%Z %z %:z %::z %:::z" 1700000000 "Australia/Lord_Howe")

(format-time-string "%Z %z %:z %::z %:::z" 1720000000 "Australia/Lord_Howe")

(format-time-string "%Z %z %:z %::z %:::z" 0 3661)

(format-time-string "%Z %z %:z %::z %:::z" 0 -19800)

(format-time-string "%Z %z" 0 '(-18000 "EST"))

(format-time-string "%Z %z" 0 '(0 "-00"))

(format-time-string "%Z %z" 0 "<-00>0")

(format-time-string "%Z %z" 15552000 "XST5XDT,M3.2.0,M11.1.0")

(format-time-string "%Z %z" 0 "EST5EDT")

(format-time-string "%Z %z" 0 ":America/New_York")

(format-time-string "[%-z|%_z|%0z|%+z|%10z|%_10z|%-10z]" 0 -18000)

(format-time-string "[%::::z|%:y|%:]" 0 19800)

(format-time-string "[%N|%3N|%12N|%-N|%_12N|%-3N|%_3N|%6N]" '(0 0 5 6))

(format-time-string "%N" 1.25)

(format-time-string "[%5%|%%|%-%|%E%|%O%|%5]" 0 t)

(format-time-string "%" 0 t)

(format-time-string "[%C|%y|%G|%g|%V|%U|%W|%j|%u|%w]" -70000000000 t)

(format-time-string "[%C|%y|%G|%g|%V|%U|%W|%j|%u|%w|%q]" 1700000000 t)

(format-time-string "[%G|%V|%g]" (encode-time '(0 0 0 1 1 2021 nil nil t)) t)

(format-time-string "[%G|%V|%g]" (encode-time '(0 0 0 31 12 2024 nil nil t)) t)

(format-time-string "[%s|%10s|%-s]" -70000000000 t)

(format-time-string "%s" 1700000000 "America/New_York")

(format-time-string "%F|%10F|%_F|%-F|%+F|%_12F|%3F|%12F" 0 t)

(format-time-string "%F" 300000000000 t)

(format-time-string "%Y|%+Y|%+6Y|%_6Y|%-Y|%06Y" 300000000000 t)

(format-time-string "%Y|%C|%y" -62200000000 t)

(format-time-string "%^Z|%#Z|%^#Z" 0 "America/New_York")

(format-time-string "%k|%l|%I|%e|%_d|%-d|%0e|%-e|%_H|%H" 3600 t)

(format-time-string "%I %l" 46800 t)

(format-time-string "%D|%R|%T|%n|%t|%Od|%OY|%Eq" 1700000000 t)

(format-time-string "%EH|%Ez|%Es|%ON|%Q|%Oa|%Eb|%Oc|%OX|%Ox" 3600 t)

(format-time-string "%^D|%#F" 1700000000 t)

(format-time-string "a\0%Y\0" 0 t)

(format-time-string "%\0" 0 t)

(format-time-string "%Y" 67768036191676799 t)

(format-time-string "%Y" 67768036191676800 t)

(format-time-string "%Y" (expt 2 63) t)

(format-time-string "%Y" '(1 . 0))

(format-time-string 5 0)

(format-time-string 5 'x)

(format-time-string "%Y" 0 'foo)

(format-time-string "%Y" 0 1.5)

(format-time-string "%Y" 0 '(3600))

(format-time-string "%Y" 0 '(3600 . "x"))

(format-time-string "%Y" 0 '(3600 x))

(format-time-string "%a %b" 0 t)

(format-time-string "%A %B %h %p %P %r %c %x %X" 0 t)

(format-time-string "%Ec %EC %Ex %EX %EY %Ey %Ob %OB" 0 t)

(format-time-string "%z" 0 t)

(format-time-string "\u00e9 %Y" 0 t)

(format-time-string "%Y" 0 "garbage")

(format-time-string "%Y" 0 90000)

(format-time-string "%Y" 0 '(3600 "XY"))

(format-time-string "%-999999999Y" 0 t)
