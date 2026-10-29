; profile: table
; mode: eval
; case_fold: nil
; format: every directive, flags, width, precision and field numbers, integers of every size, floats, and the error data; error and user-error format their message.

(format "abc")

(format "%%|%5%|%-5%")

(format "%s|%S|%s|%s" 1.5 "a\"b" 'sym nil)

(format "%s" '(1 "a" b))

(format "%S" '(1 "a" b))

(format "%-5S|%5s|" 'a t)

(format "%s" ?a)

; naive: !! (error Not enough arguments for format string)
(format "%0$s" 1)

(format "%2$s %1$s %s" 1 2 3)

(format "%1$s %1$s %s" 1 2)

(format "%3$s %s" 1 2 3)

(format "%s")

(format "%")

(format "%5")

(format "%q" 1)

(format "%é" 1)

(format "%$s" 1)

(format "%-1$d|" 3)

(format "%1$-5d|" 3)

(format "%99999999999999999999d" 1)

(format "%5c|%-5c|%.0c|%c" ?a ?b ?c ?é)

(format "%3c|%.1c|" ?字 ?字)

(format "%.0c|%5c|%05c|" ?- ?- ?a)

(format "%c" -1)

(format "%c" 4194304)

(format "%c" 2305843009213693951)

(format "%d|%i|%o|%x|%X" 42 -42 8 255 255)

(format "%.0d|%+.0d|%.0x|%#.0o|%#x|%#X|%#o" 0 0 0 0 255 255 8)

(format "%x|%X|%o" -255 -255 -8)

(format "%#x|%#o|%#x" 0 0 -255)

(format "%#5o|%#05x|%-#8x|" 8 255 255)

(format "%010d|%010.3d|%-010d|%+010d" -42 -42 -42 42)

(format "%.3d|%.3x|%+.3o" 7 7 7)

(format "%-08d|%+ d|% d|% 5d|%0.5d" 5 5 5 5 1)

(format "%+-d|%-+d|% +d|%+ d" 1 1 1 1)

(format "%b|%.5b|%#b|%#.5b|%+b|% b|%B|%#B|%b" 5 5 5 5 5 5 5 5 -5)

(format "%d|%x|%X|%o" 1180591620717411303424 1180591620717411303424 -1180591620717411303424 1180591620717411303424)

(format "%#x|%#X|%#o|%+d|% d|%030d" 1180591620717411303424 1180591620717411303424 1180591620717411303424 1180591620717411303424 1180591620717411303424 -1180591620717411303424)

; naive: => "-000001234567890123456789012345"
(format "%.30d" -1234567890123456789012345)

(format "%.30d" -12345)

(format "%.30d|%.30d" -2305843009213693952 -2305843009213693953)

(format "%d|%x" 2305843009213693951 -2305843009213693952)

(format "%.20d" 1.5)

(format "%d|%d|%+d|% d|%05d" -0.5 1.0e20 0.0 0.0 -3.7)

; naive: => "00inf|-inf|+inf|  inf"
(format "%.5d|%d|%+d|%05d" 1.0e+INF -1.0e+INF 1.0e+INF 1.0e+INF)

(format "%d" 0.0e+NaN)

(format "%d" -0.0e+NaN)

(format "%x|%x|%x" -0.5 1.0e20 -1.0e20)

(format "%x" 1.8446744073709552e19)

(format "%x" 1.0e+INF)

(format "%o" 0.0e+NaN)

(format "%e|%g|%f" 1e308 1e-5 0.1)

(format "%e|%e|%e" 0.0 -0.0 12)

(format "%g|%g|%g|%g|%g" 0.0 1e-4 1e-5 123456.0 1234567.0)

(format "%#.3g|%g|%g|%#g" 1.0 100000.0 1000000.0 1.0)

(format "%.0e|%#.0e|%.0f|%#.0f|%.0g|%#.0g" 2.5 2.5 2.5 2.5 2.5 2.5)

(format "%.1f|%.2f|%.0f|%.0f|%.3f" 0.25 0.125 0.5 1.5 1.0005)

(format "%010.3f|%-10.3f|%+.2e|% g" -3.14159 2.5 12345.678 0.0001)

(format "%.3g|%.10g|%g" 1e100 (/ 1.0 3) 1e-310)

(format "%e|%g" 5e-324 5e-324)

(format "%f" 1.7976931348623157e308)

(format "%.99f" 0.1)

(format "%.100f" 0.1)

(format "%.17g|%.17e" 0.1 0.1)

(format "%f|%+f|% e|%010f|%-10g|" 1.0e+INF 1.0e+INF -1.0e+INF 1.0e+INF 1.0e+INF)

(format "%010f" 0.0e+NaN)

(format "%f" -0.0e+NaN)

(format "%+f" 0.0e+NaN)

(format "%.2f|%f" 1180591620717411303424 9007199254740992)

(format "%f" 9007199254740993)

(format "%d" "a")

(format "%c" 1.0)

(format 'a)

(format)

(error "%s and %d" "a" 1)

(user-error "x %S" "y")

(condition-case e (error "%d%%" 5) (error (car (cdr e))))

(error "%d" 'a)

(error "%s")
