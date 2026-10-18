;;; emacs.el --- Emacs side of the export conformance gate  -*- lexical-binding: t -*-
;;;
;;; (conformance-run LISTFILE OUTDIR OPTION) exports each case and writes
;;; OUTDIR/<basename>.out.  A case's first line "# conformance: BACKEND
;;; body|full" picks the backend:
;;;
;;;   ascii, md, texinfo  org-export-as with that backend
;;;   icalendar           org-icalendar-export-to-ics on a copy of the case
;;;   icalendar-combine   org-icalendar-combine-agenda-files over the case
;;;   org                 org-element-interpret-data of the parsed buffer
;;;   opml                expected/<basename>.out (no Emacs exporter exists)
;;;
;;; An export error becomes the output "EXPORT-ERROR: <message>".  The
;;; random generator is seeded with the case's basename, so generated
;;; anchors do not depend on the rest of the corpus.

(load (expand-file-name "../_clock.el" (file-name-directory load-file-name)) nil t)
(conformance-clock-pin)

(require 'org)
(require 'org-id)
(require 'ox-ascii)
(require 'ox-md)
(require 'ox-texinfo)
(require 'ox-icalendar)
(require 'org-inlinetask)

(defconst conformance--dir (file-name-directory load-file-name))

(setq user-full-name ""
      user-mail-address ""
      org-export-creator-string "Emacs (Org mode)"
      org-export-with-broken-links t
      org-id-locations-file (make-temp-file "conformance-ids")
      org-resource-download-policy nil
      org-babel-default-header-args
      (cons '(:eval . "never-export")
            (assq-delete-all :eval (copy-alist org-babel-default-header-args)))
      org-babel-default-inline-header-args
      (cons '(:eval . "never-export")
            (assq-delete-all :eval (copy-alist org-babel-default-inline-header-args)))
      org-babel-default-lob-header-args
      (cons '(:eval . "never-export")
            (assq-delete-all :eval (copy-alist org-babel-default-lob-header-args))))

(defun conformance--mode (file)
  "Return (BACKEND . BODY-ONLY) declared by FILE's first line."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (if (looking-at "# conformance: \\([a-z-]+\\) \\(body\\|full\\)$")
        (cons (match-string 1) (equal (match-string 2) "body"))
      (error "%s: no conformance header" file))))

(defun conformance--slurp (file)
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents file))
    (buffer-string)))

(defun conformance--ics (file)
  "Export a copy of FILE, so the .ics lands in a scratch directory."
  (let* ((dir (make-temp-file "conformance-ics" t))
         (copy (expand-file-name (file-name-nondirectory file) dir)))
    (unwind-protect
        (progn
          (copy-file file copy)
          (let ((buf (let ((coding-system-for-read 'utf-8)) (find-file-noselect copy t))))
            (unwind-protect
                (with-current-buffer buf
                  (conformance--slurp (org-icalendar-export-to-ics)))
              (kill-buffer buf))))
      (delete-directory dir t))))

(defun conformance--ics-combine (file)
  (let* ((out (make-temp-file "conformance-combined" nil ".ics"))
         (org-agenda-files (list file))
         (org-icalendar-combined-agenda-file out))
    (unwind-protect
        (progn
          (org-icalendar-combine-agenda-files)
          (conformance--slurp out))
      (delete-file out))))

(defun conformance--export (file backend body)
  (let ((buf (let ((coding-system-for-read 'utf-8)) (find-file-noselect file t))))
    (unwind-protect
        (with-current-buffer buf
          (random (file-name-nondirectory file))
          (condition-case err
              (pcase backend
                ("icalendar" (conformance--ics file))
                ("icalendar-combine" (conformance--ics-combine file))
                ("org" (org-element-interpret-data (org-element-parse-buffer)))
                ("opml" (conformance--slurp
                         (expand-file-name
                          (concat "expected/" (file-name-nondirectory file) ".out")
                          conformance--dir)))
                (_ (org-export-as (intern backend) nil nil body)))
            (error (format "EXPORT-ERROR: %s\n" (error-message-string err)))))
      (kill-buffer buf))))

(defun conformance-run (listfile outdir _option)
  (dolist (file (with-temp-buffer
                  (insert-file-contents listfile)
                  (split-string (buffer-string) "\n" t)))
    (let* ((mode (conformance--mode file))
           (text (conformance--export file (car mode) (cdr mode))))
      (let ((coding-system-for-write 'utf-8-unix))
        (with-temp-file (expand-file-name (concat (file-name-nondirectory file) ".out")
                                          outdir)
          (insert text))))))
