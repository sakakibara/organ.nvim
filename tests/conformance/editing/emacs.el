;;; emacs.el --- Emacs side of the editing conformance gate  -*- lexical-binding: t -*-
;;;
;;; Each case is loaded into a fresh org-mode buffer without its leading
;;; `# key: value' header lines.  Point goes to the `@@C@@' marker and
;;; the mark to `@@M@@' (both removed), the operation named by `# op:'
;;; runs, and the result is printed in the shape organ.lua prints (see
;;; NORMALIZE.md).

(load (expand-file-name "../_clock.el" (file-name-directory load-file-name)))
(conformance-clock-pin)
(set-terminal-coding-system 'utf-8)
(require 'org)
(require 'org-element)
(require 'org-list)
(require 'org-tempo)
(require 'cl-lib)

(setq org-todo-keywords
      '((sequence "TODO" "NEXT" "WAITING" "HOLD" "PROJ" "|" "DONE" "CANCELLED")))

(defconst conformance-setups
  '(("alpha-lists" (org-list-allow-alphabetical . t))
    ("odd-levels" (org-odd-levels-only . t))
    ("respect-content" (org-insert-heading-respect-content . t))
    ("split")
    ("adapt-t" (org-adapt-indentation . t))
    ("adapt-hd" (org-adapt-indentation . headline-data))
    ("modify-bullet" (org-list-demote-modify-bullet . (("-" . "+") ("1." . "-"))))
    ("modify-bullet-dash" (org-list-demote-modify-bullet . (("-" . "+"))))
    ("checkbox-flat" (org-checkbox-hierarchical-statistics . nil))
    ("todo-flat" (org-hierarchical-todo-statistics . nil))
    ("tags-column-40" (org-tags-column . 40)))
  "Named settings a case enables with `# setup: NAME'.")

(defconst conformance-vis-ops
  '("sparse-todo" "sparse-todo-keyword" "sparse-tag" "sparse-occur" "sparse-match"
    "sparse-match-todo" "startup" "overview" "overview-cycle" "tab" "global-cycle" "speed"))

(defconst conformance-uncursored-ops '("format" "fill"))

(defconst conformance-value-ops
  '("allowed-values" "inherited-property" "inherited-property-all" "inherited-tags"
    "org-indent" "narrow"))

(defun conformance--lines (text)
  (split-string (if (string-suffix-p "\n" text) (substring text 0 -1) text) "\n"))

(defun conformance--split-header (text)
  "Return (HEADERS . BODY): the leading `# key: value' lines and the rest."
  (let ((headers nil) (start 0))
    (while (string-match "\\`# \\([a-z-]+\\): ?\\(.*\\)\n" (substring text start))
      (push (cons (match-string 1 (substring text start))
                  (match-string 2 (substring text start)))
            headers)
      (setq start (+ start (match-end 0))))
    (cons (nreverse headers) (substring text start))))

(defun conformance--words (headers key)
  (let ((v (cdr (assoc key headers))))
    (and v (split-string-and-unquote v))))

(defun conformance--pos (pos)
  (save-excursion
    (save-restriction
      (widen)
      (goto-char pos)
      (format "%d:%d" (line-number-at-pos) (- (point) (line-beginning-position))))))

(defun conformance--vis ()
  (let (out)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (push (concat (if (invisible-p (line-beginning-position)) "H|" "V|")
                      (buffer-substring-no-properties (line-beginning-position)
                                                      (line-end-position)))
              out)
        (forward-line 1)))
    (nreverse out)))

(defun conformance--with-region (mark fn)
  (when mark
    (transient-mark-mode 1)
    (push-mark mark t t)
    (activate-mark))
  (funcall fn))

(defun conformance--headline-lines (fn)
  "Call FN at each headline; collect \"LINE<TAB>VALUE\" rows."
  (let (rows)
    (org-map-entries
     (lambda () (push (format "%d\t%s" (line-number-at-pos) (funcall fn)) rows)))
    (nreverse rows)))

(defun conformance--speed (key)
  (let* ((org-use-speed-commands t)
         (cmd (org-speed-command-activate key)))
    (cond ((null cmd) (error "no speed command"))
          ((commandp cmd) (call-interactively cmd))
          ((functionp cmd) (funcall cmd))
          ((consp cmd) (eval cmd t)))))

(defun conformance--run-op (op args mark)
  "Run OP; return a list of value lines for a value op, else nil."
  (pcase op
    ("meta-return" (call-interactively 'org-meta-return) nil)
    ("insert-todo" (call-interactively 'org-insert-todo-heading) nil)
    ("insert-heading-rc" (call-interactively 'org-insert-heading-respect-content) nil)
    ("insert-todo-rc" (call-interactively 'org-insert-todo-heading-respect-content) nil)
    ("insert-subheading" (call-interactively 'org-insert-subheading) nil)
    ("promote" (org-promote-subtree) nil)
    ("demote" (org-demote-subtree) nil)
    ("promote-headline" (org-do-promote) nil)
    ("demote-headline" (org-do-demote) nil)
    ("demote-region" (conformance--with-region mark #'org-do-demote) nil)
    ("move-up" (org-move-subtree-up) nil)
    ("move-down" (org-move-subtree-down) nil)
    ("toggle-comment" (org-toggle-comment) nil)
    ((or "cut-paste" "copy-paste")
     (if (equal op "cut-paste") (org-cut-subtree) (org-copy-subtree))
     (goto-char (point-min))
     (search-forward "PP")
     (replace-match "" t t)
     (org-paste-subtree)
     nil)
    ("narrow" (org-narrow-to-subtree) (conformance--lines (buffer-string)))
    ("mark-subtree" (org-mark-subtree) nil)
    ("sort-entries" (org-sort-entries nil (string-to-char (car args)) nil nil (cadr args)) nil)
    ("cycle-bullet" (org-cycle-list-bullet (and args 'previous)) nil)
    ("item-indent" (org-metaright) nil)
    ("item-indent-tree" (org-shiftmetaright) nil)
    ("item-outdent-tree" (org-shiftmetaleft) nil)
    ("item-indent-region" (conformance--with-region mark #'org-shiftmetaright) nil)
    ((or "list-repair" "format-list") (org-list-repair) nil)
    ("list-sort" (org-sort-list nil (string-to-char (car args))) nil)
    ("item-move-down" (org-move-item-down) nil)
    ("list-to-subtree" (org-list-make-subtree) nil)
    ("toggle-checkbox" (org-toggle-checkbox) nil)
    ("toggle-checkbox-remove" (org-toggle-checkbox '(4)) nil)
    ("toggle-checkbox-region" (conformance--with-region mark #'org-toggle-checkbox) nil)
    ("update-statistics" (org-update-statistics-cookies t) nil)
    ("todo" (org-todo) nil)
    ("set-property" (org-set-property (car args) (cadr args)) nil)
    ("delete-property" (org-delete-property (car args)) nil)
    ("allowed-values"
     (let ((v (org-property-get-allowed-values nil (car args))))
       (if v (mapcar (lambda (s) (format "%S" s)) v) (list "nil"))))
    ("inherited-property"
     (list (format "%S" (org-entry-get nil (car args) t))))
    ("inherited-property-all"
     (conformance--headline-lines (lambda () (or (org-entry-get nil (car args) t) ""))))
    ("inherited-tags"
     (conformance--headline-lines
      (lambda () (mapconcat #'identity (sort (copy-sequence (org-get-tags)) #'string<) ","))))
    ("fast-tags"
     (let ((unread-command-events (listify-key-sequence (concat (car args) "\r"))))
       (org-set-tags-command))
     nil)
    ("set-tags" (org-set-tags (car args)) nil)
    ("align-tags" (org-align-tags t) nil)
    ("sparse-todo" (org-show-todo-tree nil) nil)
    ("sparse-todo-keyword"
     (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (car args)))
               ((symbol-function 'read-string) (lambda (&rest _) (car args))))
       (org-show-todo-tree '(4)))
     nil)
    ("sparse-tag" (org-match-sparse-tree nil (car args)) nil)
    ("sparse-occur" (org-occur (car args)) nil)
    ("sparse-match" (org-match-sparse-tree nil (car args)) nil)
    ("sparse-match-todo" (org-match-sparse-tree t (car args)) nil)
    ("startup" (org-cycle-set-startup-visibility) nil)
    ("overview" (org-overview) nil)
    ("overview-cycle"
     (org-overview)
     (goto-char (point-min))
     (dotimes (i (string-to-number (car args)))
       (let ((last-command (if (> i 0) 'org-cycle nil))
             (this-command 'org-cycle))
         (org-cycle)))
     nil)
    ("tab" (let ((last-command nil)) (org-cycle)) nil)
    ("global-cycle"
     (org-cycle-set-startup-visibility)
     (let ((last-command nil)) (org-global-cycle))
     nil)
    ("emphasize"
     (let ((ch (if (equal (car args) "SPC") ?\s (string-to-char (car args)))))
       (conformance--with-region mark (lambda () (org-emphasize ch))))
     nil)
    ("fill" (fill-paragraph) nil)
    ("tempo" (org-tempo-setup) (tempo-complete-tag) nil)
    ("structure-template"
     (conformance--with-region mark (lambda () (org-insert-structure-template (car args))))
     nil)
    ((or "priority-shiftup" "timestamp-shiftup") (org-shiftup) nil)
    ((or "priority-shiftdown" "timestamp-shiftdown") (org-shiftdown) nil)
    ("priority-up" (let ((last-command nil)) (org-priority 'up)) nil)
    ("priority-down" (let ((last-command nil)) (org-priority 'down)) nil)
    ("format"
     (let ((s (org-element-interpret-data (org-element-parse-buffer))))
       (erase-buffer)
       (insert s))
     nil)
    ("toggle-heading" (conformance--with-region mark #'org-toggle-heading) nil)
    ("toggle-item" (conformance--with-region mark (lambda () (org-toggle-item nil))) nil)
    ("indent-region" (indent-region (point-min) (point-max)) nil)
    ("org-indent"
     (org-indent-mode 1)
     (org-indent-refresh-maybe (point-min) (point-max) nil)
     (let (out)
       (goto-char (point-min))
       (while (not (eobp))
         (push (format "lp=%d|%s"
                       (length (or (get-text-property (point) 'line-prefix) ""))
                       (buffer-substring-no-properties (line-beginning-position)
                                                       (line-end-position)))
               out)
         (forward-line 1))
       (nreverse out)))
    ("speed" (conformance--speed (car args)) nil)
    (_ (message "conformance: unknown op %s" op) (kill-emacs 3))))

(defun conformance--render (file option)
  (let* ((text (with-temp-buffer
                 (let ((coding-system-for-read 'utf-8)) (insert-file-contents file))
                 (buffer-string)))
         (split (conformance--split-header text))
         (headers (car split))
         (op-spec (conformance--words headers "op"))
         (op (car op-spec))
         (setups (conformance--words headers "setup"))
         (options (conformance--words headers "options"))
         (bindings (apply #'append (mapcar (lambda (s) (cdr (assoc s conformance-setups))) setups))))
    (if (and option (not (member option options)))
        "n/a\n"
      (let ((buf (generate-new-buffer "case.org"))
            status values cursor mark-pos final vis)
        (switch-to-buffer buf)
        (insert (cdr split))
        (cl-progv (mapcar #'car bindings) (mapcar #'cdr bindings)
          (org-mode)
          (let ((case-fold-search nil) (mk nil) (pt (point-min)))
            (goto-char (point-min))
            (when (search-forward "@@M@@" nil t)
              (replace-match "" t t)
              (setq mk (point)))
            (goto-char (point-min))
            (when (search-forward "@@C@@" nil t)
              (replace-match "" t t)
              (setq pt (point))
              (when (and mk (> mk pt)) (setq mk (- mk 5))))
            (goto-char pt)
            (setq mk (and mk (copy-marker mk)))
            (condition-case nil
                (setq values (conformance--run-op op (cdr op-spec) mk))
              (error (setq status "! error")))
            (setq cursor (conformance--pos (point)))
            (when (and (equal op "mark-subtree") (region-active-p))
              (setq mark-pos (concat "mark " (conformance--pos (mark)))))
            (when (member op conformance-vis-ops) (setq vis (conformance--vis)))
            (widen)
            (setq final (buffer-string))))
        (set-buffer-modified-p nil)
        (kill-buffer buf)
        (concat
         (mapconcat #'identity
                    (append (and status (list status))
                            (cond ((member op conformance-value-ops) values)
                                  (vis vis)
                                  (t (conformance--lines final)))
                            (and (not (member op conformance-value-ops))
                                 (not (member op conformance-uncursored-ops))
                                 (list "--- point" cursor))
                            (and mark-pos (list mark-pos)))
                    "\n")
         "\n")))))

(defun conformance-run (listfile outdir option)
  (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
            ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
            ((symbol-function 'read-file-name) (lambda (&rest _) "include.org")))
    (dolist (file (conformance--lines
                   (with-temp-buffer (insert-file-contents listfile) (buffer-string))))
      (let ((out (let ((inhibit-message t)) (conformance--render file option)))
            (coding-system-for-write 'utf-8-unix))
        (with-temp-file (expand-file-name (concat (file-name-nondirectory file) ".out") outdir)
          (insert out))))))
