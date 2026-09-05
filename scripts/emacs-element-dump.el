;;; emacs-element-dump.el --- Canonical structural dump via org-element
;;;
;;; Usage:
;;;   emacs --batch -Q -l scripts/emacs-element-dump.el \
;;;     --eval '(organ-element-dump "/path/to/listfile")'
;;;
;;; LISTFILE holds one absolute .org path per line.  For each file the
;;; dump prints, in document order:
;;;
;;;   F <TAB> path
;;;   H <TAB> level <TAB> todo <TAB> priority <TAB> tags <TAB> title
;;;   X <TAB> COMMENT | ARCHIVE
;;;   S <TAB> raw timestamp          (SCHEDULED)
;;;   D <TAB> raw timestamp          (DEADLINE)
;;;   C <TAB> raw timestamp          (CLOSED)
;;;   P <TAB> key <TAB> value        (one per node property)
;;;
;;; Tabs, newlines and backslashes inside a field are backslash-escaped
;;; so every record stays on one line.
;;;
;;; scripts/organ-element-dump.lua prints the identical format from
;;; organ's tree-sitter parse; scripts/diff-against-emacs.sh diffs the
;;; two.  Both sides pin the same configuration so a difference is a
;;; real parser divergence and not a settings mismatch:
;;;
;;;   * organ's default TODO sequence, so `PROJ' is a keyword on both
;;;     sides and `HOLD' is not a title word,
;;;   * `org-inlinetask' loaded, so a 15-star line is an inline task
;;;     rather than a very deep headline,
;;;   * priority printed with `char-to-string' (org-element stores the
;;;     character, organ stores the letter),
;;;   * `org-element-use-cache' nil, TZ=UTC, C locale, so repeated runs
;;;     on any host agree.

(require 'org)
(require 'org-element)
(require 'org-inlinetask)

(setenv "TZ" "UTC")
(setq system-time-locale "C")
(setq org-element-use-cache nil)
(setq org-todo-keywords
      '((sequence "TODO" "NEXT" "WAITING" "HOLD" "PROJ" "|" "DONE" "CANCELLED")))

(defun organ-element-dump--escape (s)
  (let ((s (substring-no-properties (or s ""))))
    (replace-regexp-in-string
     "\n" "\\\\n"
     (replace-regexp-in-string
      "\t" "\\\\t"
      (replace-regexp-in-string "\\\\" "\\\\\\\\" s)))))

(defun organ-element-dump--raw (timestamp)
  (if (null timestamp)
      ""
    (or (org-element-property :raw-value timestamp)
        (org-element-interpret-data timestamp)
        "")))

(defun organ-element-dump--section-children (headline type)
  "Direct children of HEADLINE's own section that have element TYPE."
  (let (found)
    (dolist (child (org-element-contents headline))
      (when (eq (org-element-type child) 'section)
        (dolist (grandchild (org-element-contents child))
          (when (eq (org-element-type grandchild) type)
            (push grandchild found)))))
    (nreverse found)))

(defun organ-element-dump--headline (headline)
  (let ((out '()))
    (push (format "H\t%d\t%s\t%s\t%s\t%s"
                  (org-element-property :level headline)
                  (organ-element-dump--escape
                   (org-element-property :todo-keyword headline))
                  (let ((priority (org-element-property :priority headline)))
                    (if priority (char-to-string priority) ""))
                  (organ-element-dump--escape
                   (mapconcat #'identity
                              (org-element-property :tags headline) ","))
                  (organ-element-dump--escape
                   (org-element-property :raw-value headline)))
          out)
    (when (org-element-property :commentedp headline)
      (push "X\tCOMMENT" out))
    (when (org-element-property :archivedp headline)
      (push "X\tARCHIVE" out))
    (dolist (planning (organ-element-dump--section-children headline 'planning))
      (dolist (entry '((:scheduled . "S") (:deadline . "D") (:closed . "C")))
        (let ((timestamp (org-element-property (car entry) planning)))
          (when timestamp
            (push (format "%s\t%s" (cdr entry)
                          (organ-element-dump--escape
                           (organ-element-dump--raw timestamp)))
                  out)))))
    (dolist (drawer (organ-element-dump--section-children
                     headline 'property-drawer))
      (dolist (property (org-element-contents drawer))
        (when (eq (org-element-type property) 'node-property)
          (push (format "P\t%s\t%s"
                        (organ-element-dump--escape
                         (org-element-property :key property))
                        (organ-element-dump--escape
                         (or (org-element-property :value property) "")))
                out))))
    (nreverse out)))

(defun organ-element-dump-buffer ()
  (let ((tree (org-element-parse-buffer))
        (out '()))
    (org-element-map tree 'headline
      (lambda (headline)
        (setq out (nconc out (organ-element-dump--headline headline)))))
    out))

(defun organ-element-dump (listfile)
  "Print the canonical structural dump of every .org path in LISTFILE."
  (let ((files (with-temp-buffer
                 (insert-file-contents listfile)
                 (split-string (buffer-string) "\n" t))))
    (dolist (file files)
      (princ (format "F\t%s\n" file))
      (condition-case err
          (with-temp-buffer
            (insert-file-contents file)
            (let ((org-inhibit-startup t))
              (org-mode))
            (dolist (record (organ-element-dump-buffer))
              (princ record)
              (princ "\n")))
        (error
         (message "emacs-element-dump: %s: %s" file (error-message-string err))
         (kill-emacs 1))))))

(provide 'emacs-element-dump)
