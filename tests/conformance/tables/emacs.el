;;; emacs.el --- Emacs side of the tables conformance gate  -*- lexical-binding: t -*-
;;;
;;; Each case is run in a fresh org-mode buffer: point goes to the `@@C@@'
;;; marker (removed) or point-min, the operation named by the case's
;;; `# op:' header runs (default recalc; a .csv/.tsv/.txt/.dat case is
;;; imported into an empty buffer), and the buffer is printed in the
;;; shape tests/conformance/tables/organ.lua prints (see NORMALIZE.md).

(load (expand-file-name "../_clock.el" (file-name-directory load-file-name)))
(conformance-clock-pin)
(set-terminal-coding-system 'utf-8)
(require 'org)
(require 'org-table)
(require 'cl-lib)

(defvar conformance-cases-dir nil)

(defconst conformance-raw-ops '("align" "format" "tab" "shift-tab" "import"))
(defconst conformance-cursor-ops '("tab" "shift-tab"))

(defun conformance--header (text key)
  (when (string-match (concat "\\`\\(?:# [a-z]+:.*\n\\)*?# " key ": *\\(.*\\)$") text)
    (split-string (match-string 1 text) " +" t)))

(defun conformance--goto-table ()
  (unless (org-at-table-p)
    (goto-char (point-min))
    (re-search-forward "^[ \t]*|")))

(defun conformance--cells (line)
  (let* ((s (replace-regexp-in-string "\\`[ \t]*|" "" line))
         (s (replace-regexp-in-string "|[ \t]*\\'" "" s)))
    (mapconcat (lambda (c) (string-trim c "[ \t]+" "[ \t]+"))
               (split-string s "|") "\t")))

(defun conformance--render-lines (lines)
  (mapcar (lambda (l)
            (cond ((string-match-p "\\`[ \t]*|-" l) "|-")
                  ((string-match-p "\\`[ \t]*|" l) (concat "|" (conformance--cells l)))
                  (t l)))
          lines))

(defun conformance--lines (text)
  (split-string (if (string-suffix-p "\n" text) (substring text 0 -1) text) "\n"))

(defun conformance--run-op (op args file)
  (pcase op
    ("recalc" (conformance--goto-table) (org-table-recalculate t))
    ("recalc-line" (org-table-recalculate nil))
    ("iterate" (conformance--goto-table) (org-table-iterate))
    ("ctrl-c-ctrl-c" (org-ctrl-c-ctrl-c))
    ("align" (conformance--goto-table) (org-ctrl-c-ctrl-c))
    ("format" (org-table-map-tables #'org-table-align t))
    ("tab" (org-cycle))
    ("shift-tab" (org-shifttab))
    ("insert-row-above" (org-table-insert-row))
    ("insert-row-below" (org-table-insert-row t))
    ("delete-row" (org-table-kill-row))
    ("move-row-up" (org-table-move-row-up))
    ("move-row-down" (org-table-move-row-down))
    ("insert-column-left" (org-table-insert-column))
    ("delete-column" (org-table-delete-column))
    ("move-column-left" (org-table-move-column-left))
    ("move-column-right" (org-table-move-column-right))
    ("sort" (org-table-sort-lines nil (string-to-char (car args))))
    ("import" (org-table-import (expand-file-name (car args) conformance-cases-dir) nil))
    ("export"
     (let ((tmp (make-temp-name (expand-file-name "conformance-export-" temporary-file-directory))))
       (conformance--goto-table)
       (unwind-protect
           (progn
             (org-table-export tmp (concat "orgtbl-to-" (car args)))
             (with-temp-buffer
               (insert-file-contents tmp)
               (buffer-string)))
         (when (file-exists-p tmp) (delete-file tmp)))))
    (_ (error "conformance: unknown op %s" op))))

(defun conformance--render (file option)
  (let* ((text (with-temp-buffer
                 (let ((coding-system-for-read 'utf-8)) (insert-file-contents file))
                 (buffer-string)))
         (ext (file-name-extension file))
         (import-case (member ext '("csv" "tsv" "txt" "dat")))
         (op-spec (if import-case
                      (list "import" (file-name-nondirectory file))
                    (or (conformance--header text "op") '("recalc"))))
         (op (car op-spec))
         (options (conformance--header text "options"))
         (status nil) (exported nil) (cursor nil) (final nil))
    (if (and option (not (member option options)))
        "n/a\n"
      (with-temp-buffer
        (insert (if import-case "\n" text))
        (org-mode)
        (goto-char (point-min))
        (when (let ((case-fold-search nil)) (search-forward "@@C@@" nil t))
          (replace-match "" t t))
        (condition-case nil
            (let* ((coding-system-for-read 'utf-8)
                   (r (conformance--run-op op (cdr op-spec) file)))
              (when (equal op "export") (setq exported r)))
          (error (setq status "! error")))
        (setq cursor (format "@ %d:%d" (line-number-at-pos)
                             (- (point) (line-beginning-position))))
        (setq final (buffer-string)))
      (let* ((lines (conformance--lines final))
             (out (append (and status (list status)) (conformance--render-lines lines))))
        (when (member op conformance-cursor-ops)
          (setq out (append out (list cursor))))
        (when exported
          (setq out (append out (list "--- export") (conformance--lines exported))))
        (when (member op conformance-raw-ops)
          (setq out (append out (list "--- raw") lines)))
        (concat (mapconcat #'identity out "\n") "\n")))))

(defun conformance-run (listfile outdir option)
  (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
            ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
    (dolist (file (conformance--lines
                   (with-temp-buffer (insert-file-contents listfile) (buffer-string))))
      (setq conformance-cases-dir (file-name-directory file))
      (let ((out (let ((inhibit-message t)) (conformance--render file option)))
            (coding-system-for-write 'utf-8-unix))
        (with-temp-file (expand-file-name (concat (file-name-nondirectory file) ".out") outdir)
          (insert out))))))
