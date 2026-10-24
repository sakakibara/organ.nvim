;;; emacs.el --- Emacs side of the elisp conformance gate  -*- lexical-binding: t -*-
;;;
;;; `conformance-run' groups the cases by the profile their header names
;;; and starts one Emacs per profile, so features one profile loads never
;;; reach another.  Each child loads its profile's features, reads every
;;; item of its cases from the UTF-8 case file and writes one line per
;;; item, in the shape tests/conformance/elisp/organ.lua writes (see
;;; NORMALIZE.md).

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

(defconst conformance-elisp-modes '("read"))

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

(defun conformance-elisp--read-item (source)
  (condition-case err
      (let ((value (car (read-from-string source))))
        (concat "=> " (let ((print-escape-newlines t))
                        (prin1-to-string value))))
    (error (concat "!! " (conformance-elisp--oneline (format "%s" err))))))

(defun conformance-elisp--render (file)
  (let* ((parsed (conformance-elisp--parse (conformance-elisp--text file)))
         (mode (cdr (assoc "mode" (car parsed))))
         (n 0)
         lines)
    (unless (member mode conformance-elisp-modes)
      (error "conformance: %s: unknown mode %s" file mode))
    (with-temp-buffer
      (org-mode)
      (dolist (item (cdr parsed))
        (setq n (1+ n))
        (let ((line (conformance-elisp--read-item (cdr item))))
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
