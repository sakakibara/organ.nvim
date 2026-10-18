;;; _clock.el --- Pin the current time for an Emacs conformance run  -*- lexical-binding: t -*-
;;;
;;; (conformance-clock-pin) fixes "now" at CONFORMANCE_NOW ("YYYY-MM-DD
;;; HH:MM", UTC; default 2026-05-04 09:30) for every time primitive org
;;; reads, so both sides of a gate see the same day.  tests/conformance/
;;; _clock.lua pins organ to the same instant.

(defvar conformance-clock--now nil)

(defun conformance-clock--parse (s)
  (encode-time (list 0 (string-to-number (substring s 14 16))
                     (string-to-number (substring s 11 13))
                     (string-to-number (substring s 8 10))
                     (string-to-number (substring s 5 7))
                     (string-to-number (substring s 0 4)) nil nil "UTC")))

(defun conformance-clock--filter (pos)
  (lambda (args)
    (if (and (>= (length args) (1+ pos)) (nth pos args))
        args
      (let ((a (copy-sequence args)))
        (while (< (length a) (1+ pos)) (setq a (append a (list nil))))
        (setf (nth pos a) conformance-clock--now)
        a))))

(defun conformance-clock-pin ()
  (setq conformance-clock--now
        (conformance-clock--parse (or (getenv "CONFORMANCE_NOW") "2026-05-04 09:30")))
  (advice-add 'current-time :override (lambda () conformance-clock--now))
  (advice-add 'format-time-string :filter-args (conformance-clock--filter 1))
  (advice-add 'decode-time :filter-args (conformance-clock--filter 0))
  (advice-add 'float-time :filter-args (conformance-clock--filter 0))
  (advice-add 'current-time-string :filter-args (conformance-clock--filter 0))
  (advice-add 'time-convert :filter-args (conformance-clock--filter 0))
  (dolist (f '(time-less-p time-equal-p time-subtract time-add))
    (advice-add f :filter-args
                (lambda (args) (mapcar (lambda (x) (or x conformance-clock--now)) args))))
  (with-eval-after-load 'org
    (advice-add 'org-today :override
                (lambda () (time-to-days conformance-clock--now)))))
