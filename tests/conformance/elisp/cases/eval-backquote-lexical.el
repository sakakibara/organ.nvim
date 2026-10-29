; profile: prefix
; mode: eval
; case_fold: nil
; Backquote expansion (backquote.el), lexical binding.

`a

`(a b)

`(a ,(car '(1)) c)

`(a ,@(list 1 2) c)

`(a ,@(list 1 2))

`(a . ,(car '(1)))

`(,@'(1 2) . 3)

`[a ,(car '(1))]

`[a ,@(list 1 2) b]

`[a b]

`[,@(list 1)]

`(a ,@1)

`(,@(list 1) ,@(list 2))

`(a `(b ,(c ,(car '(1)))))

`(1 ,@nil 2)

`(,@nil)

`(\, a b)

`(\,@ a b)

`(a . (\, (car '(1))))

`,(car '(1))

`,@(list 1)

`nil

`t

`:k

`"s"

`(a ,'b)

`(,'(quote x))

`(a ,(quote x y))

(let ((b 5)) `(a ,@b))

(let ((a 1) (b 5)) `[,a ,@b])

`(a ,@"ab" c)

`(a ,@[1 2] c)

`(a ,@(car '(1)) c)

(\`)

(\` a b)

(backquote (a ,(car '(1))))

,a

,@a

`(a `(b ,c))

`(a `(b ,,(car '(1))))

`(a `(b ,@,(car '((1 2)))))

`[a [b ,(car '(1))]]

`(a [b ,(car '(1))] . c)

`(,@(list 1 2) . ,(car '(3)))

`((,(car '(1))) ,@(list 2) 3 ,4)

`(a ,@(list 1) . b)

`(a ,@'(1 . 2))

`(a ,@(cons 1 2) b)

`(,@(list 1) ,@(cons 2 3))

`(a ,@(list 1 2) ,(car '(3)) ,@(list 4))

`(a b ,@(list 1))

`(a b . ,(list 1))

`[,(car '(1)) ,@(cons 2 3)]

`(a ,(\` b))

`(a . `b)

(let ((x '(1 2))) (list `(,@x) x))

`((a . ,(car '(1))) (b . 2))

`(\, . a)

`(a \, . b)
