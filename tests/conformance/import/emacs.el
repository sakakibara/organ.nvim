;;; emacs.el --- Import gate: reference HTML and the org export of organ's import  -*- lexical-binding: t -*-
;;;
;;; Emacs has no Markdown importer, so the reference side of this gate is
;;; the expected HTML each case carries (the CommonMark / GFM spec's own,
;;; or a cmark-gfm form for the custom cases).  (conformance-run ...)
;;; writes it out.  (conformance-import-export DIR) is the organ side's
;;; Emacs step: organ.lua runs it once per case to export the org that
;;; organ's import produced.  Settings are listed in NORMALIZE.md.

(load (expand-file-name "../_clock.el" (file-name-directory load-file-name)) nil t)
(conformance-clock-pin)

(require 'org)
(require 'ox-html)

(setq org-export-with-toc nil
      org-export-with-section-numbers nil
      org-export-headline-levels 8
      org-html-toplevel-hlevel 1
      org-html-checkbox-type 'html
      org-html-htmlize-output-type nil
      org-export-use-babel nil)

(defconst conformance-import--fence (make-string 32 ?`))

(defun conformance-import--read (path)
  (with-temp-buffer
    (set-buffer-multibyte t)
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents path))
    (buffer-string)))

(defun conformance-import--write (path text)
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file path (insert text))))

(defun conformance-import--examples (path)
  "Examples of case file PATH as a list of (LABEL MARKDOWN HTML)."
  (let ((lines (split-string (conformance-import--read path) "\n"))
        (open (concat conformance-import--fence " example"))
        label state md html out)
    (dolist (line lines)
      (cond
       ((eq state 'md)
        (if (string= line ".") (setq state 'html) (push line md)))
       ((eq state 'html)
        (if (string= line conformance-import--fence)
            (progn
              (push (list label
                          (concat (mapconcat #'identity (nreverse md) "\n") "\n")
                          (if html
                              (concat (mapconcat #'identity (nreverse html) "\n") "\n")
                            ""))
                    out)
              (setq state nil md nil html nil))
          (push line html)))
       ((string-prefix-p "## " line) (setq label (substring line 3)))
       ((string= line open) (setq state 'md))))
    (nreverse out)))

(defun conformance-run (listfile outdir _option)
  (dolist (case (split-string (conformance-import--read listfile) "\n" t))
    (conformance-import--write
     (expand-file-name (concat (file-name-nondirectory case) ".out") outdir)
     (mapconcat (lambda (ex) (format "=== %s ===\n%s" (nth 0 ex) (nth 2 ex)))
                (conformance-import--examples case) ""))))

(defun conformance-import-export (dir)
  "Export DIR/<name>.org to DIR/<name>.html for each name in DIR/list.
An export error is written to DIR/<name>.err instead."
  (dolist (name (split-string (conformance-import--read (expand-file-name "list" dir)) "\n" t))
    (let ((org (conformance-import--read (expand-file-name (concat name ".org") dir))))
      (condition-case err
          (conformance-import--write (expand-file-name (concat name ".html") dir)
                                     (org-export-string-as org 'html t))
        (error
         (conformance-import--write (expand-file-name (concat name ".err") dir)
                                    (error-message-string err)))))))
