;;; emacs-op.el --- Generic org-mode operation runner for parity tests
;;;
;;; Usage:
;;;   emacs --batch -Q -l scripts/emacs-op.el \
;;;     --eval '(organ-op-run "<op>" "<input-file>")'
;;;
;;; <input-file> is a path to a file containing the org source.  An
;;; optional `<CURSOR>' marker indicates where the operation should
;;; run from (cursor-dependent ops only); defaults to point-min.
;;;
;;; The output is the resulting buffer content, printed to stdout
;;; with no trailing newline added (so byte-diff against organ's
;;; output is straightforward).
;;;
;;; Adding a new op: extend the `cond' in `organ-op-run' with a clause
;;; that performs the operation on the prepared buffer and `princ's
;;; the result.  Keep it pure: no agenda buffers, no file writes, no
;;; side effects.  For cursor-position-dependent ops, place point via
;;; the `<CURSOR>' marker rather than hard-coding goto-char.
;;;
;;; Determinism (mirrors emacs-agenda-snapshot.el): TZ=UTC,
;;; LC_TIME=C, `org-today' / `current-time' pinned via fixed-today.
;;; Most parity ops don't depend on the date, but pinning costs
;;; nothing and prevents flakes when an op DOES (e.g. timestamp-
;;; relative repeat-shift on `org-auto-repeat-maybe').

(require 'cl-lib)
(require 'org)

(setenv "TZ" "UTC")
(setq system-time-locale "C")

(defconst organ-op--cursor-marker "<CURSOR>"
  "Literal string searched-for in input to locate where ops should run.")

(defconst organ-op--pinned-iso "2026-05-04"
  "Pinned `today' for date-sensitive ops.  Bump intentionally.")

(defun organ-op--setup-buffer (input)
  "Insert INPUT, parse out the cursor marker, enable org-mode."
  (insert input)
  (goto-char (point-min))
  (when (search-forward organ-op--cursor-marker nil t)
    (replace-match "" t t))
  (org-mode))

(defun organ-op--with-pinned-today (body)
  "Run BODY thunk with `current-time' and `org-today' pinned to
`organ-op--pinned-iso'."
  (let* ((iso organ-op--pinned-iso)
         (year  (string-to-number (substring iso 0 4)))
         (month (string-to-number (substring iso 5 7)))
         (day   (string-to-number (substring iso 8 10)))
         (pinned-time (encode-time 0 0 12 day month year))
         (pinned-absolute (calendar-absolute-from-gregorian
                           (list month day year))))
    (advice-add 'org-today :override (lambda () pinned-absolute))
    (unwind-protect
        (cl-letf (((symbol-function 'current-time) (lambda () pinned-time)))
          (funcall body))
      (advice-remove 'org-today (lambda () pinned-absolute)))))

(defun organ-op-run (op input-file)
  "Apply OP to the contents of INPUT-FILE and print result to stdout."
  (let ((input (with-temp-buffer
                 (insert-file-contents input-file)
                 (buffer-string))))
    (with-temp-buffer
      (organ-op--setup-buffer input)
      (organ-op--with-pinned-today
       (lambda ()
         (cond
          ;; ---------------------------------------------------------------
          ;; Formatter ops
          ;; ---------------------------------------------------------------
          ((string= op "fill-paragraph")
           (fill-paragraph)
           (princ (buffer-string)))
          ;; ---------------------------------------------------------------
          ;; TODO state ops
          ;; ---------------------------------------------------------------
          ((string= op "org-todo")
           ;; `org-todo' with no prefix advances to the next state.
           (org-todo)
           (princ (buffer-string)))
          ((string= op "org-shiftleft")
           ;; Cycle backward (org-shiftleft on a TODO state).
           (org-shiftleft)
           (princ (buffer-string)))
          ((string= op "org-shiftright")
           ;; Cycle forward via the arrow alt path (should match
           ;; `org-todo' on a TODO state).
           (org-shiftright)
           (princ (buffer-string)))
          ;; ---------------------------------------------------------------
          ;; Repeater ops (`org-auto-repeat-maybe' fires when marking DONE)
          ;; ---------------------------------------------------------------
          ((string= op "org-todo-done")
           (org-todo "DONE")
           (princ (buffer-string)))
          (t (error "unknown op: %s" op))))))))

(provide 'emacs-op)
;;; emacs-op.el ends here
