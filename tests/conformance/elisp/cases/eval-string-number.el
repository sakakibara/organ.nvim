; profile: table
; mode: eval
; case_fold: nil
; number-to-string and string-to-number: the leading number in base 10 or BASE, trailing text ignored, 0 when none.

(number-to-string 0)

(number-to-string -15)

(number-to-string 1.0)

(number-to-string -0.0)

(number-to-string 1e+21)

(number-to-string 0.1)

(number-to-string 1180591620717411303424)

(number-to-string 1.0e+INF)

(number-to-string 0.0e+NaN)

(number-to-string 'a)

(number-to-string "1")

(string-to-number "12")

(string-to-number " \t12abc")

; naive: => 12
(string-to-number "\n12")

; naive: => 1.0
(string-to-number "1.")

(string-to-number "1.e5")

(string-to-number ".5")

(string-to-number "-.5e-3x")

(string-to-number "-")

(string-to-number "")

(string-to-number "-0")

(string-to-number "-0.0")

(string-to-number "+12")

(string-to-number "+-12")

(string-to-number "1_000")

(string-to-number "0x10")

(string-to-number "1e5")

(string-to-number "1E5")

(string-to-number "1e")

(string-to-number "1e+")

(string-to-number "1e400")

(string-to-number "4.9e-325")

(string-to-number "2.4703282292062328e-324")

(string-to-number "0e+INF")

(string-to-number "-1.0e+INF")

(string-to-number ".e+INF")

(string-to-number "1.5e+INF")

(string-to-number "1e+NaN")

(string-to-number "9007199254740993")

(string-to-number "-123456789012345678901234567890")

(string-to-number "99999999999999999999999999999999999999999999999999e-30")

(string-to-number "ff" 16)

(string-to-number "-FF" 16)

(string-to-number "1.5" 16)

(string-to-number "102" 2)

(string-to-number "777777777777777777777777" 8)

(string-to-number "g" 16)

(string-to-number "10" 1)

(string-to-number "10" 17)

(string-to-number "Z" 36)

(string-to-number "10" 1.0)

(string-to-number "10" 1180591620717411303424)

(string-to-number "10" 36028797018963968)

(string-to-number "10" nil)

(string-to-number 'a)

(string-to-number)
