; profile: var
; mode: eval
; case_fold: nil
; org-lookup-* with closure predicates under lexical binding.

(let ((k 1)) (org-lookup-all 2 '(1 2 3) '(a b c) (lambda (v s) (> (+ s k) v))))

(let ((seen nil)) (org-lookup-last 0 '(1 2 3) nil (lambda (v s) (setq seen (cons s seen)) (> s v))) seen)

(let ((n 0)) (org-lookup-first 0 '(1 2 3) nil (lambda (v s) (setq n (1+ n)) (> s v))) n)

(org-lookup-first 2 '(1 2) nil (lambda (v) v))
