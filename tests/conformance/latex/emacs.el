;;; emacs.el --- Emacs side of the latex conformance gate  -*- lexical-binding: t -*-
;;;
;;; (conformance-run LISTFILE OUTDIR OPTION) exports each case with
;;; ox-latex (OPTION nil) or ox-beamer (OPTION "beamer") and writes
;;; OUTDIR/<basename>.out.  A case's first line "# conformance: BACKEND
;;; body|full" picks its backend and whether the whole document or only
;;; the body is exported (default: latex body).  A case of the other
;;; backend writes an empty output.  An export error becomes the output
;;; "EXPORT-ERROR: <message>".  The random generator is seeded with the
;;; case's basename, so its generated labels do not depend on the corpus.

(load (expand-file-name "../_clock.el" (file-name-directory load-file-name)) nil t)
(conformance-clock-pin)

(require 'org)
(require 'ox-latex)
(require 'ox-beamer)
(require 'org-inlinetask)

(setq user-full-name ""
      user-mail-address ""
      org-export-creator-string "Emacs (Org mode)"
      org-resource-download-policy nil
      org-babel-default-header-args
      (cons '(:eval . "never-export")
            (assq-delete-all :eval (copy-alist org-babel-default-header-args))))

(defun conformance--mode (file)
  "Return (BACKEND . BODY-ONLY) declared by FILE's first line."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (if (looking-at "# conformance: \\([a-z]+\\) \\(body\\|full\\)$")
        (cons (match-string 1) (equal (match-string 2) "body"))
      (cons "latex" t))))

(defun conformance--export (file backend body)
  (let ((buf (let ((coding-system-for-read 'utf-8)) (find-file-noselect file t))))
    (unwind-protect
        (with-current-buffer buf
          (random (file-name-nondirectory file))
          (condition-case err
              (org-export-as (intern backend) nil nil body)
            (error (format "EXPORT-ERROR: %s\n" (error-message-string err)))))
      (kill-buffer buf))))

(defun conformance-run (listfile outdir option)
  (let ((want (or option "latex")))
    (dolist (file (with-temp-buffer
                    (insert-file-contents listfile)
                    (split-string (buffer-string) "\n" t)))
      (let* ((mode (conformance--mode file))
             (text (if (equal (car mode) want)
                       (conformance--export file want (cdr mode))
                     "")))
        (let ((coding-system-for-write 'utf-8))
          (with-temp-file (expand-file-name (concat (file-name-nondirectory file) ".out")
                                            outdir)
            (insert text)))))))
