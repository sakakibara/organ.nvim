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

(defconst organ-section--pinned-out
  (encode-time 0 30 13 4 5 2026)           ; 2026-05-04 13:30:00, clock-out
  "Fixed clock-out time.")

(defun organ-section--dump-file (path)
  "Return the literal text of PATH."
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun organ-section--apply (seed-name buf)
  "Apply the OPS.md sequence for SEED-NAME to org BUF.
Covers planning, property, and CLOSED ops; logbook ops use
`organ-section--apply-logbook'."
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

(defun organ-section--flush-log-note ()
  "Flush any pending log note immediately.
In batch mode the post-command hook check on `this-command' prevents
`org-add-log-note' from running automatically; call this after any op
that schedules a note via `org-add-log-setup'."
  (when (and (boundp 'org-log-setup) org-log-setup
             (memq org-log-note-how '(time state)))
    (org-add-log-note)))

(defun organ-section--apply-logbook (seed-name buf)
  "Apply logbook (state note + clock) ops, into the :LOGBOOK: drawer."
  (with-current-buffer buf
    (org-mode)
    (goto-char (point-min))
    (let ((org-todo-keywords '((sequence "TODO(t)" "|" "DONE(d!)")))
          (org-log-into-drawer t)
          (org-clock-into-drawer t)
          (org-log-done 'time))
      (org-set-regexps-and-options)
      (pcase seed-name
        ("04-logbook.org"
         (org-todo "DONE")
         (organ-section--flush-log-note)
         (cl-letf (((symbol-function 'current-time) (lambda () organ-section--pinned)))
           (org-clock-in))
         (cl-letf (((symbol-function 'current-time) (lambda () organ-section--pinned-out)))
           (org-clock-out)))
        ("05-full.org"
         (org-schedule nil "2026-05-06")
         (org-deadline nil "2026-05-07")
         (org-set-property "FOO" "bar")
         (org-todo "DONE")
         (organ-section--flush-log-note)
         (cl-letf (((symbol-function 'current-time) (lambda () organ-section--pinned)))
           (org-clock-in))
         (cl-letf (((symbol-function 'current-time) (lambda () organ-section--pinned-out)))
           (org-clock-out)))))))

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
