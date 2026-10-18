;;; emacs.el --- Emacs side of the agenda conformance gate  -*- lexical-binding: t -*-
;;;
;;; (conformance-run LISTFILE OUTDIR OPTION) renders each case's agenda
;;; views and writes OUTDIR/<basename>.out: per view a "=== VIEW" line,
;;; then the visible text of the agenda buffer.  The case format (header
;;; keys, files, views) is described in NORMALIZE.md.  A view that
;;; signals writes "ERROR: <message>".  An option run renders only the
;;; cases that list the option; the others write a fixed line.  Cases
;;; that turn habits on load org-habit, which cannot be unloaded, so
;;; they run after every other case.

(load (expand-file-name "../_clock.el" (file-name-directory load-file-name)) nil t)
(conformance-clock-pin)

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-agenda)

(defconst conformance--todo-keywords
  '((sequence "TODO" "NEXT" "WAITING" "HOLD" "PROJ" "|" "DONE" "CANCELLED")))

(setq system-time-locale "C"
      org-todo-keywords conformance--todo-keywords)

(defun conformance--parse-case (file)
  "Return (HEADER . FILES) for case FILE.
HEADER is an alist of (KEY . VALUE) in order; FILES a list of (NAME . TEXT)."
  (let ((lines (with-temp-buffer
                 (let ((coding-system-for-read 'utf-8))
                   (insert-file-contents file))
                 (split-string (buffer-string) "\n")))
        (header '()) (files '()) (name nil) (body '()))
    (when (equal (car (last lines)) "")
      (setq lines (butlast lines)))
    (dolist (line lines)
      (cond
       ((string-match "\\`#\\+CONFORMANCE-FILE: \\(.+\\)\\'" line)
        (when name (push (cons name (nreverse body)) files))
        (setq name (match-string 1 line) body '()))
       ((and (null name)
             (string-match "\\`#\\+CONFORMANCE-\\([A-Z]+\\): \\(.*\\)\\'" line))
        (push (cons (match-string 1 line) (match-string 2 line)) header))
       (name (push line body))))
    (when name (push (cons name (nreverse body)) files))
    (cons (nreverse header)
          (mapcar (lambda (f) (cons (car f) (mapconcat #'identity (cdr f) "\n")))
                  (nreverse files)))))

(defun conformance--values (header key)
  (delq nil (mapcar (lambda (h) (and (equal (car h) key) (cdr h))) header)))

(defun conformance--visible-text ()
  "The agenda buffer's text without invisible characters."
  (let ((out '()) (pos (point-min)))
    (while (< pos (point-max))
      (let ((next (next-char-property-change pos)))
        (unless (invisible-p pos)
          (push (buffer-substring-no-properties pos next) out))
        (setq pos next)))
    (apply #'concat (nreverse out))))

(defun conformance--view-form (spec)
  (let* ((parts (split-string spec " " t))
         (kind (car parts))
         (arg (string-trim (substring spec (length kind)))))
    (pcase kind
      ("day" `(org-agenda-list nil ,(and (> (length arg) 0) arg) 'day))
      ("week" `(org-agenda-list nil ,(and (> (length arg) 0) arg) 'week))
      ("month" `(org-agenda-list nil ,arg 'month))
      ("default" '(org-agenda-list))
      ("todo" '(org-todo-list))
      ("tags" `(org-tags-view nil ,arg))
      ("tags-todo" `(org-tags-view t ,arg))
      ("search" `(org-search-view nil ,arg))
      ("stuck" '(org-agenda-list-stuck-projects))
      ("composite"
       '(let ((org-agenda-custom-commands
               '(("x" "Composite"
                  ((agenda "" ((org-agenda-span 'day)))
                   (alltodo "")
                   (tags "home"))))))
          (org-agenda nil "x")))
      (_ (error "Unknown view %s" spec)))))

(defun conformance--render-view (spec)
  (condition-case err
      (progn
        (when (get-buffer org-agenda-buffer-name)
          (kill-buffer org-agenda-buffer-name))
        (eval (conformance--view-form spec) t)
        (with-current-buffer org-agenda-buffer-name
          (string-remove-suffix "\n" (conformance--visible-text))))
    (error (format "ERROR: %s" (error-message-string err)))))

(defun conformance--render-case (case-file option)
  (let* ((parsed (conformance--parse-case case-file))
         (header (car parsed))
         (options (split-string (or (car (conformance--values header "OPTIONS")) "") " " t)))
    (if (and option (not (member option options)))
        (format "(not in the %s run)\n" option)
      (let* ((dir (make-temp-file "agenda-case" t))
             (paths (mapcar (lambda (f)
                              (let ((path (expand-file-name (car f) dir)))
                                (let ((coding-system-for-write 'utf-8))
                                  (with-temp-file path (insert (cdr f) "\n")))
                                path))
                            (cdr parsed)))
             (todo (car (conformance--values header "TODO")))
             (bindings (mapcar (lambda (s) (car (read-from-string s)))
                               (conformance--values header "EMACS")))
             (out '()))
        (setq conformance-clock--now
              (conformance-clock--parse
               (or (car (conformance--values header "NOW")) "2026-05-04 09:30")))
        (cl-progv
            (append '(org-agenda-files org-todo-keywords) (mapcar #'car bindings))
            (append (list paths
                          (if todo
                              (list (cons 'sequence (split-string todo " " t)))
                            conformance--todo-keywords))
                    (mapcar (lambda (b) (eval (cadr b) t)) bindings))
          (dolist (spec (conformance--values header "VIEW"))
            (push (format "=== %s\n%s\n" spec (conformance--render-view spec)) out)))
        (dolist (path paths)
          (let ((buf (find-buffer-visiting path)))
            (when buf (kill-buffer buf))))
        (delete-directory dir t)
        (apply #'concat (nreverse out))))))

(defun conformance-run (listfile outdir option)
  (let* ((cases (with-temp-buffer
                  (insert-file-contents listfile)
                  (split-string (buffer-string) "\n" t)))
         (habits (cl-remove-if-not
                  (lambda (c)
                    (conformance--values (car (conformance--parse-case c)) "HABITS"))
                  cases)))
    (dolist (case-file (append (cl-set-difference cases habits :test #'equal) habits))
      (when (and (member case-file habits) (not (featurep 'org-habit)))
        (require 'org-habit))
      (let ((text (conformance--render-case case-file option)))
        (let ((coding-system-for-write 'utf-8))
          (with-temp-file (expand-file-name
                           (concat (file-name-nondirectory case-file) ".out") outdir)
            (insert text)))))))
