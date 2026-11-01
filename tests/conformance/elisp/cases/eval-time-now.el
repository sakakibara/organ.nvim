; profile: table
; mode: eval
; case_fold: nil
; The current time, for shape only: current-time, float-time and the functions where nil stands for now.

(length (current-time))

(integerp (car (current-time)))

(floatp (float-time))

(floatp (float-time nil))

(length (decode-time))

(length (decode-time nil t))

(stringp (format-time-string "%Y"))

(consp (time-add nil 0))

(length (time-subtract nil 0))

(time-less-p 0 nil)

(time-equal-p nil nil)

(time-subtract nil nil)

(current-time 1)
