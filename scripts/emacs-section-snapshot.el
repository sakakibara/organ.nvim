;;; emacs-section-snapshot.el --- Dump org file text after a fixed op sequence
;;;
;;; Usage:
;;;   emacs --batch -Q -l scripts/emacs-section-snapshot.el \
;;;     --eval '(organ-section-snapshot "/abs/path/to/seed-dir")'
;;;
;;; Applies the OPS.md matrix to a temp copy of each seed and prints, to
;;; stdout, each result file separated by a "==> name" banner. Determinism
;;; is pinned exactly as emacs-agenda-snapshot.el does (TZ, locale, clock).

(require 'cl-lib)
(require 'org)
(require 'org-clock)

(defconst organ-section--pinned
  (encode-time 0 0 12 4 5 2026)            ; 2026-05-04 12:00:00
  "Fixed `current-time' for op application.")

(defun organ-section--dump-file (path)
  "Return the literal text of PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun organ-section--apply (seed-name buf)
  "Apply the OPS.md sequence for SEED-NAME to org BUF. Logbook ops live in a
later task's `organ-section--apply-logbook'; this covers planning/property/CLOSED."
  (with-current-buffer buf
    (org-mode)
    (goto-char (point-min))
    (pcase seed-name
      ("01-close.org"
       (let ((org-log-done 'time)) (org-todo "DONE")))
      ("02-plan.org"
       (org-schedule nil "2026-05-06")
       (org-deadline nil "2026-05-07")
       (let ((org-log-done 'time)) (org-todo "DONE")))
      ("03-prop-then-plan.org"
       (org-schedule nil "2026-05-06")))))

;; Replaced by a later task. Defined here so seeds 04/05 don't error.
(defun organ-section--apply-logbook (_name _buf) nil)

(defun organ-section-snapshot (seed-dir)
  "Apply ops to each seed in SEED-DIR and print results to stdout."
  (setenv "TZ" "UTC")
  (setq system-time-locale "C")
  (cl-letf (((symbol-function 'current-time) (lambda () organ-section--pinned)))
    (dolist (seed (sort (directory-files seed-dir t "\\.org\\'") #'string<))
      (let* ((name (file-name-nondirectory seed))
             (tmp (make-temp-file "organ-sec-" nil ".org")))
        (copy-file seed tmp t)
        (let ((buf (find-file-noselect tmp)))
          (if (member name '("04-logbook.org" "05-full.org"))
              (organ-section--apply-logbook name buf)
            (organ-section--apply name buf))
          (with-current-buffer buf (save-buffer))
          (princ (format "==> %s\n" name))
          (princ (organ-section--dump-file tmp))
          (princ "\n"))
        (delete-file tmp)))))

;;; emacs-section-snapshot.el ends here
