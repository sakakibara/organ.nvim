; profile: diary
; mode: eval
; case_fold: nil
; date: (10 24 2026)
; entry: Ent %d%s
; XT-10: a diary sexp that is one call of diary-date, diary-anniversary, diary-cyclic
; or diary-block with literal arguments reads a date triple year-first when its first
; value is a number above 31, or t while its last is a plain day.  Other forms follow
; Emacs.

(diary-date 2026 10 24)

(diary-date t 10 24)

(diary-date 10 24 t)

(diary-date t 10 2026)

(diary-anniversary 2000 10 24)

(diary-cyclic 7 2026 10 3)

(diary-block 2026 10 1 2026 10 31)

(diary-block 10 1 2026 2026 10 31)

(diary-date 2026 10 24 'm)

(diary-date 2026 10 (+ 20 4))

(progn (diary-date 2026 10 24))

(diary-date 2026.0 10 24)
