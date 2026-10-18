;;; emacs.el --- Emacs side of the html conformance gate  -*- lexical-binding: t -*-
;;;
;;; (conformance-run LISTFILE OUTDIR OPTION) exports each .org case as a
;;; full ox-html document and writes OUTDIR/<basename>.out.  A case that
;;; is not an .org file is a fixture another case reads (#+INCLUDE,
;;; #+SETUPFILE, #+bibliography) and writes "fixture: <basename>".  An
;;; export error becomes the output "EXPORT-ERROR: <message>".  The
;;; settings below are listed with their reasons in NORMALIZE.md.

(load (expand-file-name "../_clock.el" (file-name-directory load-file-name)) nil t)
(conformance-clock-pin)

(setenv "HOME" "/home/conformance")

(require 'org)
(require 'ox-html)
(require 'org-inlinetask)

(setq vc-handled-backends nil
      user-full-name ""
      user-mail-address ""
      org-export-creator-string "Emacs (Org mode)"
      org-export-with-broken-links 'mark
      org-html-prefer-user-labels t
      org-todo-keywords
      '((sequence "TODO" "NEXT" "WAITING" "HOLD" "PROJ" "|" "DONE" "CANCELLED"))
      org-babel-default-header-args
      (cons '(:eval . "never-export")
            (assq-delete-all :eval (copy-alist org-babel-default-header-args))))

(defun conformance--export (file)
  (let ((buf (let ((coding-system-for-read 'utf-8)) (find-file-noselect file t))))
    (unwind-protect
        (with-current-buffer buf
          (condition-case err
              (org-export-as 'html)
            (error (format "EXPORT-ERROR: %s\n" (error-message-string err)))))
      (kill-buffer buf))))

(defun conformance-run (listfile outdir _option)
  (dolist (file (with-temp-buffer
                  (insert-file-contents listfile)
                  (split-string (buffer-string) "\n" t)))
    (let ((text (if (string-suffix-p ".org" file)
                    (conformance--export file)
                  (format "fixture: %s\n" (file-name-nondirectory file)))))
      (let ((coding-system-for-write 'utf-8))
        (with-temp-file (expand-file-name (concat (file-name-nondirectory file) ".out")
                                          outdir)
          (insert text))))))
