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
          ;; ---------------------------------------------------------------
          ;; List-item indent ops.  `org-shiftmetaright` is the general
          ;; demote (works on any list item, empty or not); the Tab-on-
          ;; empty-bullet UX path (`org-cycle-item-indentation`) is a
          ;; restricted special case of the same demote.  Our `list.demote`
          ;; targets the general behavior, so use `org-shiftmetaright`
          ;; for the parity baseline.  Cursor placed via `<CURSOR>`.
          ((string= op "list-demote")
           (org-shiftmetaright)
           (princ (buffer-string)))
          ((string= op "list-promote")
           (org-shiftmetaleft)
           (princ (buffer-string)))
          ;; ---------------------------------------------------------------
          ;; Heading promote / demote (M-Right / M-Left / `org-demote` /
          ;; `org-promote`).  `org-odd-levels-only` (a buffer-local toggle)
          ;; makes each step bump the star count by 2 instead of 1, so
          ;; promote/demote always land on an odd valid level.  Set via
          ;; `(setq-local org-odd-levels-only t)` in the setup eval.
          ;; ---------------------------------------------------------------
          ((string= op "heading-demote")
           (org-do-demote)
           (princ (buffer-string)))
          ((string= op "heading-promote")
           (org-do-promote)
           (princ (buffer-string)))
          ;; ---------------------------------------------------------------
          ;; Inheritance probes -- dump each headline + its effective tags
          ;; (direct + inherited), sorted, one per line.  Used to verify
          ;; our tag-inheritance computation against `org-get-tags' which
          ;; is the canonical Emacs op respecting `org-use-tag-inheritance'.
          ;; ---------------------------------------------------------------
          ((string= op "dump-tags")
           (let ((rows '()))
             (org-map-entries
              (lambda ()
                (let* ((heading (substring-no-properties
                                 (org-get-heading t t t t)))
                       (tags (sort (copy-sequence (org-get-tags))
                                   #'string<)))
                  (push (format "%s\t%s"
                                heading
                                (mapconcat #'identity tags ","))
                        rows))))
             (princ (mapconcat #'identity (nreverse rows) "\n"))
             (princ "\n")))
          ;; Inline-markup probe -- dump each emphasis element in
          ;; document order.  Emacs `org-element-parse-buffer' resolves
          ;; the pre/post-char rules from `org-emphasis-regexp-
          ;; components' so this is the ground truth for "what is and
          ;; isn't recognized as bold/italic/etc."
          ((string= op "dump-emphasis")
           (let ((tree (org-element-parse-buffer))
                 (rows '()))
             (org-element-map tree
                 '(bold italic underline strike-through code verbatim)
               (lambda (el)
                 (let* ((type (org-element-type el))
                        (text (if (memq type '(code verbatim))
                                  (or (org-element-property :value el) "")
                                (buffer-substring-no-properties
                                 (org-element-property :contents-begin el)
                                 (org-element-property :contents-end el)))))
                   (push (format "%s\t%s" type text) rows))))
             (princ (mapconcat #'identity (nreverse rows) "\n"))
             (princ "\n")))
          ;; Property probe -- dump each headline + a chosen property's
          ;; value (with inheritance), one per line.  PROPERTY is read
          ;; from `organ-op--property' bound by the caller via --eval
          ;; before invoking organ-op-run.
          ((string= op "dump-property")
           (let ((rows '())
                 (prop (or (and (boundp 'organ-op--property)
                                organ-op--property)
                           "CATEGORY")))
             (org-map-entries
              (lambda ()
                (let ((heading (substring-no-properties
                                (org-get-heading t t t t)))
                      (val (or (org-entry-get nil prop t) "")))
                  (push (format "%s\t%s" heading val) rows))))
             (princ (mapconcat #'identity (nreverse rows) "\n"))
             (princ "\n")))
          (t (error "unknown op: %s" op))))))))

(provide 'emacs-op)
;;; emacs-op.el ends here
