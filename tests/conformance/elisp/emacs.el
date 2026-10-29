;;; emacs.el --- Emacs side of the elisp conformance gate  -*- lexical-binding: t -*-
;;;
;;; `conformance-run' groups the cases by the profile their header names
;;; and starts one Emacs per profile, so features one profile loads never
;;; reach another.  Each child loads its profile's features, reads (and in
;;; `eval' mode evaluates, with the profile's binding) every item of its
;;; cases from the UTF-8 case file and writes one line per item, in the
;;; shape tests/conformance/elisp/organ.lua writes (see NORMALIZE.md).

(require 'cl-lib)

(defconst conformance-elisp-dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defconst conformance-elisp-features
  '(("table" org)
    ("diary" org org-agenda diary-lib calendar)
    ("prefix" org org-agenda)
    ("capture" org org-capture)
    ("var" org ob-core)
    ("link" org ol)))

(defconst conformance-elisp-lexical
  '(("table" . nil) ("diary" . nil) ("link" . nil)
    ("prefix" . t) ("capture" . t) ("var" . t))
  "Whether each profile's Emacs entry point evaluates with lexical binding.")

(defconst conformance-elisp-modes '("read" "eval"))

(defun conformance-elisp--text (file)
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents file))
    (buffer-string)))

(defun conformance-elisp--blocks (text)
  "Blocks of TEXT: runs of lines separated by empty lines."
  (let (blocks cur)
    (dolist (line (split-string text "\n"))
      (if (string= line "")
          (when cur (push (nreverse cur) blocks) (setq cur nil))
        (push line cur)))
    (when cur (push (nreverse cur) blocks))
    (nreverse blocks)))

(defun conformance-elisp--parse (text)
  "Return (HEADER . ITEMS) for case TEXT.
HEADER is an alist of the `; KEY: VALUE' lines of the first block;
each item is (NAIVE . SOURCE)."
  (let* ((blocks (conformance-elisp--blocks text))
         (head (car blocks))
         header items)
    (unless (and head (cl-every (lambda (l) (string-prefix-p ";" l)) head))
      (error "conformance: case has no header block"))
    (dolist (l head)
      (when (string-match "\\`; \\([a-z_]+\\): *\\(.*\\)\\'" l)
        (push (cons (match-string 1 l) (match-string 2 l)) header)))
    (dolist (b (cdr blocks))
      (let (naive)
        (while (and b (string-prefix-p "; naive: " (car b)))
          (setq naive (substring (car b) (length "; naive: "))
                b (cdr b)))
        (unless b (error "conformance: item has no source"))
        (push (cons naive (mapconcat #'identity b "\n")) items)))
    (cons (nreverse header) (nreverse items))))

(defun conformance-elisp--oneline (s)
  (replace-regexp-in-string "\n" "\\\\n" s t))

(defun conformance-elisp--unprintable-p (x)
  "Non-nil if X holds a value organ does not print in error text."
  (let ((todo (list x)) found)
    (while (and todo (not found))
      (let ((v (pop todo)))
        (cond ((consp v) (push (car v) todo) (push (cdr v) todo))
              ((vectorp v) (setq todo (append v todo)))
              ((or (subrp v) (byte-code-function-p v) (interpreted-function-p v))
               (setq found t))
              ((and (stringp v) (next-property-change 0 v)) (setq found t))
              ((and (stringp v) (text-properties-at 0 v)) (setq found t)))))
    found))

(defun conformance-elisp--error-line (err)
  (if (conformance-elisp--unprintable-p (cdr err))
      (format "!! %s <unprintable>" (car err))
    (concat "!! " (conformance-elisp--oneline (format "%s" err)))))

(defun conformance-elisp--value-line (value)
  (concat "=> " (let ((print-escape-newlines t))
                  (prin1-to-string value))))

(defun conformance-elisp--read-item (source)
  (condition-case err
      (conformance-elisp--value-line (car (read-from-string source)))
    (error (conformance-elisp--error-line err))))

(defun conformance-elisp--variables (header)
  "The `date' and `entry' bindings HEADER gives, as (SYMBOL . VALUE)."
  (let (vars)
    (let ((d (cdr (assoc "date" header))))
      (when d (push (cons 'date (car (read-from-string d))) vars)))
    (let ((e (cdr (assoc "entry" header))))
      (when e (push (cons 'entry e) vars)))
    (nreverse vars)))

(defun conformance-elisp--eval-item (source header lexical)
  "Evaluate SOURCE as PROFILE's entry point does: the header's `date'
and `entry' bound dynamically around it, `case-fold-search' from its
`case_fold', binding lexical when LEXICAL."
  (condition-case err
      (let* ((form (car (read-from-string source)))
             (vars (conformance-elisp--variables header))
             (value (let ((case-fold-search
                           (equal (cdr (assoc "case_fold" header)) "t")))
                      (cl-progv (mapcar #'car vars) (mapcar #'cdr vars)
                        (eval form lexical)))))
        (conformance-elisp--value-line value))
    (error (conformance-elisp--error-line err))))

(defun conformance-elisp--render (file)
  (let* ((parsed (conformance-elisp--parse (conformance-elisp--text file)))
         (header (car parsed))
         (mode (cdr (assoc "mode" header)))
         (lexical (cdr (assoc (cdr (assoc "profile" header)) conformance-elisp-lexical)))
         (n 0)
         lines)
    (unless (member mode conformance-elisp-modes)
      (error "conformance: %s: unknown mode %s" file mode))
    (with-temp-buffer
      (org-mode)
      (dolist (item (cdr parsed))
        (setq n (1+ n))
        (let ((line (if (equal mode "eval")
                        (conformance-elisp--eval-item (cdr item) header lexical)
                      (conformance-elisp--read-item (cdr item)))))
          (when (and (car item) (string= line (car item)))
            (error "conformance: %s item %d: Emacs gives the naive answer %s"
                   (file-name-nondirectory file) n line))
          (push line lines))))
    (mapconcat (lambda (l) (concat l "\n")) (nreverse lines) "")))

(defun conformance-elisp--profile (file)
  (let ((p (cdr (assoc "profile"
                       (car (conformance-elisp--parse
                             (conformance-elisp--text file)))))))
    (unless (assoc p conformance-elisp-features)
      (error "conformance: %s: unknown profile %s" file p))
    p))

(defun conformance-elisp-profile (profile listfile outdir)
  "Child entry: render the cases in LISTFILE under PROFILE into OUTDIR."
  (mapc #'require (cdr (assoc profile conformance-elisp-features)))
  (dolist (file (split-string (conformance-elisp--text listfile) "\n" t))
    (let ((out (conformance-elisp--render file))
          (coding-system-for-write 'utf-8-unix))
      (with-temp-file (expand-file-name
                       (concat (file-name-nondirectory file) ".out") outdir)
        (insert out)))))

(defun conformance-run (listfile outdir _option)
  (let ((groups nil))
    (dolist (file (split-string (conformance-elisp--text listfile) "\n" t))
      (let* ((p (conformance-elisp--profile file))
             (cell (assoc p groups)))
        (if cell
            (setcdr cell (cons file (cdr cell)))
          (push (list p file) groups))))
    (dolist (group (nreverse groups))
      (let ((list (make-temp-file "conformance-elisp-"))
            (coding-system-for-write 'utf-8-unix))
        (unwind-protect
            (progn
              (with-temp-file list
                (insert (mapconcat #'identity (reverse (cdr group)) "\n") "\n"))
              (with-temp-buffer
                (let ((status
                       (call-process
                        (expand-file-name invocation-name invocation-directory)
                        nil t nil "--batch" "-Q"
                        "-l" (expand-file-name "../_collate.el" conformance-elisp-dir)
                        "-l" (expand-file-name "emacs.el" conformance-elisp-dir)
                        "--eval" (format "(conformance-elisp-profile %S %S %S)"
                                         (car group) list outdir))))
                  (unless (eq status 0)
                    (error "conformance: profile %s failed (%s): %s"
                           (car group) status (buffer-string))))))
          (delete-file list))))))

;;; emacs.el ends here
