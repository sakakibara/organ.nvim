;;; emacs.el --- Emacs side of the babel-links conformance gate  -*- lexical-binding: t -*-
;;;
;;; Each case is written into a fresh directory (NORMALIZE.md, "Case
;;; format"), case.org is visited with point at `<CURSOR>', the case's
;;; operations run, and the result is printed in the shape
;;; tests/conformance/babel-links/organ.lua prints.

(load (expand-file-name "../_clock.el" (file-name-directory load-file-name)))
(conformance-clock-pin)
(set-terminal-coding-system 'utf-8)
(require 'cl-lib)
(require 'org)
(require 'ob)
(require 'ob-shell)
(require 'ob-python)
(require 'ob-emacs-lisp)
(require 'ol)
(require 'org-id)
(require 'org-footnote)
(require 'oc)
(require 'oc-basic)
(require 'browse-url)

(setq make-backup-files nil
      auto-save-default nil
      create-lockfiles nil
      enable-local-variables nil
      org-babel-python-command "python3"
      org-id-track-globally nil)

;; Case roots are made under HOME, as for most users and on CI, so stored
;; links take the `~' form on every machine.
(setenv "HOME" (directory-file-name temporary-file-directory))
(setq abbreviated-home-dir nil)

(defvar conformance--prompts nil)
(defvar conformance--opens nil)
(defvar conformance--link-answer nil)
(defvar conformance--desc-answer nil)
(defvar conformance--cite-key nil)

(defconst conformance--style-aliases
  '(("a" . "author") ("na" . "noauthor") ("n" . "nocite") ("ft" . "note")
    ("nb" . "numeric") ("t" . "text")))
(defconst conformance--variant-aliases
  '(("b" . "bare") ("c" . "caps") ("bc" . "bare-caps")))

(defun conformance--parse (text)
  "Split case TEXT into (HEADER . FILES); FILES starts with case.org."
  (let ((lines (split-string text "\n")) header files (name "case.org") body)
    (when (equal (car (last lines)) "") (setq lines (butlast lines)))
    (while (and lines
                (string-match "\\`#\\+CONFORMANCE-\\([A-Z-]+\\): \\(.*\\)\\'" (car lines))
                (not (equal (match-string 1 (car lines)) "FILE")))
      (push (cons (match-string 1 (car lines)) (match-string 2 (car lines))) header)
      (pop lines))
    (dolist (line lines)
      (if (string-match "\\`#\\+CONFORMANCE-FILE: \\(.+\\)\\'" line)
          (progn (push (cons name (nreverse body)) files)
                 (setq name (match-string 1 line) body nil))
        (push line body)))
    (push (cons name (nreverse body)) files)
    (cons (nreverse header)
          (mapcar (lambda (f) (cons (car f) (concat (mapconcat #'identity (cdr f) "\n") "\n")))
                  (nreverse files)))))

(defun conformance--values (header key)
  (delq nil (mapcar (lambda (h) (and (equal (car h) key) (cdr h))) header)))

(defun conformance--write (path content)
  (make-directory (file-name-directory path) t)
  (let ((coding-system-for-write 'utf-8-unix))
    (write-region content nil path nil 'silent)))

(defun conformance--snapshot (root)
  "Alist of (RELPATH . STATE) for every file and symlink under ROOT."
  (let (out)
    (dolist (f (directory-files-recursively root "" nil nil t))
      (let ((rel (file-relative-name f root))
            (target (file-symlink-p f)))
        (cond
         (target (push (cons rel (list 'link target)) out))
         ((file-regular-p f)
          (push (cons rel (list 'file (file-modes f)
                                (with-temp-buffer
                                  (let ((coding-system-for-read 'utf-8))
                                    (insert-file-contents f))
                                  (buffer-string))))
                out)))))
    (sort out (lambda (a b) (string< (car a) (car b))))))

(defun conformance--file-lines (before after)
  "Lines describing every path whose state differs between snapshots."
  (let (out)
    (dolist (a after)
      (unless (equal (cdr a) (cdr (assoc (car a) before)))
        (pcase (cdr a)
          (`(link ,target) (push (format "--- %s -> %s" (car a) target) out))
          (`(file ,mode ,text)
           (push (format "--- %s (%o)" (car a) (logand mode #o777)) out)
           (dolist (l (split-string (if (string-suffix-p "\n" text) (substring text 0 -1) text)
                                    "\n"))
             (push l out))))))
    (dolist (b before)
      (unless (assoc (car b) after)
        (push (format "--- %s (deleted)" (car b)) out)))
    (nreverse out)))

(defun conformance--buffer-lines ()
  (let ((s (buffer-substring-no-properties (point-min) (point-max))))
    (split-string (if (string-suffix-p "\n" s) (substring s 0 -1) s) "\n")))

(defun conformance--where (dir)
  (format "%s %d:%d"
          (if buffer-file-name
              (file-relative-name (file-truename buffer-file-name) (file-truename dir))
            (buffer-name))
          (line-number-at-pos) (current-column)))

(defun conformance--s (x)
  (let ((s (and x (string-trim (substring-no-properties (org-element-interpret-data x))))))
    (and (org-string-nw-p s) s)))

(defun conformance--style (s)
  (if (null s) "nil"
    (let* ((parts (split-string s "/"))
           (style (car parts))
           (variant (mapconcat #'identity (cdr parts) "/")))
      (concat (or (cdr (assoc style conformance--style-aliases)) style)
              (if (equal variant "") ""
                (concat "/" (or (cdr (assoc variant conformance--variant-aliases)) variant)))))))

(defun conformance--cite-dump ()
  (org-element-map (org-element-parse-buffer) 'citation
    (lambda (c)
      (format "L%d style=%s pre=%S suf=%S refs=%s"
              (line-number-at-pos (org-element-property :begin c))
              (conformance--style (org-element-property :style c))
              (conformance--s (org-element-property :prefix c))
              (conformance--s (org-element-property :suffix c))
              (mapconcat
               (lambda (r)
                 (format "(%s %S %S)" (org-element-property :key r)
                         (conformance--s (org-element-property :prefix r))
                         (conformance--s (org-element-property :suffix r))))
               (org-element-map c 'citation-reference #'identity) " ")))))

(defun conformance--store (file dir)
  (setq org-stored-links nil)
  (if file
      (with-current-buffer (find-file-noselect (expand-file-name file dir))
        (goto-char (point-min))
        (call-interactively #'org-store-link))
    (call-interactively #'org-store-link))
  (let ((st (car org-stored-links)))
    (goto-char (point-max))
    (unless (bolp) (insert "\n"))
    (call-interactively #'org-insert-link)
    (list (concat "=== stored " (or (car st) "nil"))
          (concat "=== description " (or (cadr st) "nil")))))

(defun conformance--op (spec dir)
  "Run operation SPEC; return its output lines and the section kind."
  (let* ((words (split-string spec " " t))
         (op (car words))
         (args (cdr words)))
    (pcase op
      ("execute" (org-babel-execute-maybe) nil)
      ("execute-buffer" (org-babel-execute-buffer) nil)
      ("tangle" (org-babel-tangle) nil)
      ("follow" (org-open-at-point) nil)
      ("store" (conformance--store (car args) dir))
      ("insert-link"
       (setq conformance--link-answer (car args)
             conformance--desc-answer (and (cdr args) (mapconcat #'identity (cdr args) " ")))
       (call-interactively #'org-insert-link)
       nil)
      ("fn-action" (org-footnote-action) nil)
      ("fn-new" (org-footnote-new) nil)
      ("fn-sort" (org-footnote-sort) nil)
      ("fn-normalize" (org-footnote-normalize) nil)
      ("fn-renumber" (org-footnote-renumber-fn:N) nil)
      ("fn-delete" (org-footnote-delete) nil)
      ("cite-parse" (cons "=== citations" (conformance--cite-dump)))
      ("cite-insert" (setq conformance--cite-key (car args)) (org-cite-insert nil) nil)
      ("cite-bibliography" nil)
      ("bib-files"
       (append (list "=== bibliography") (org-cite-list-bibliography-files)
               (list "=== keys") (sort (org-cite-basic--all-keys) #'string<)))
      (_ (message "conformance: unknown op %s" op) (kill-emacs 3)))))

(defconst conformance--point-ops '("follow" "fn-action" "fn-new"))
(defconst conformance--quiet-ops '("follow" "cite-parse" "bib-files"))

(defun conformance--replace-dirs (text root dir)
  (dolist (pair (list (cons (file-truename dir) "<DIR>") (cons dir "<DIR>")
                      (cons (abbreviate-file-name dir) "~<DIR>")
                      (cons (file-truename root) "<ROOT>") (cons root "<ROOT>")
                      (cons (abbreviate-file-name root) "~<ROOT>")))
    (setq text (replace-regexp-in-string
                (regexp-quote (directory-file-name (car pair))) (cdr pair) text t t)))
  text)

(defun conformance--render (file option)
  (let* ((text (with-temp-buffer
                 (let ((coding-system-for-read 'utf-8)) (insert-file-contents file))
                 (buffer-string)))
         (parsed (conformance--parse text))
         (header (car parsed))
         (options (split-string (or (car (conformance--values header "OPTIONS")) "") " " t)))
    (if (and option (not (member option options)))
        (format "(not in the %s run)\n" option)
      (let* ((root (directory-file-name (make-temp-file "conformance-bl" t)))
             (dir (expand-file-name "w" root))
             (ops (conformance--values header "OP"))
             (bindings (mapcar (lambda (b) (car (read-from-string b)))
                               (conformance--values header "EMACS")))
             (option-bindings (and (equal option "id-link-nil")
                                   '((org-id-link-to-org-use-id nil))))
             (out nil) before buf)
        (make-directory dir t)
        (dolist (f (cdr parsed)) (conformance--write (expand-file-name (car f) dir) (cdr f)))
        (dolist (d (conformance--values header "DIR")) (make-directory (expand-file-name d dir) t))
        (dolist (s (conformance--values header "SYMLINK"))
          (let ((w (split-string s " " t)))
            (make-symbolic-link (cadr w) (expand-file-name (car w) dir))))
        (setq before (conformance--snapshot root))
        (setq conformance--prompts nil conformance--opens nil
              conformance--link-answer nil conformance--desc-answer nil
              conformance--cite-key nil org-stored-links nil)
        (let ((vars (mapcar #'car (append bindings option-bindings)))
              (vals (mapcar (lambda (b) (eval (cadr b) t)) (append bindings option-bindings)))
              (default-directory (file-name-as-directory dir)))
          (cl-progv vars vals
            (setq buf (find-file (expand-file-name "case.org" dir)))
            (with-current-buffer buf
              (let ((case-fold-search nil) mark)
                (goto-char (point-min))
                (when (search-forward "<MARK>" nil t)
                  (replace-match "" t t)
                  (setq mark (point)))
                (goto-char (point-min))
                (when (search-forward "<CURSOR>" nil t)
                  (replace-match "" t t))
                (set-buffer-modified-p nil)
                (when mark
                  (transient-mark-mode 1)
                  (push-mark mark t t)))
              (dolist (form (conformance--values header "EMACS-EVAL"))
                (eval (car (read-from-string form)) t))
              (dolist (spec ops)
                (let ((lines (condition-case nil
                                 (conformance--op spec dir)
                               (error (list (concat "! error " spec))))))
                  (setq out (append out lines))))
              (let ((op (car (split-string (car ops) " " t))))
                (when (member op conformance--point-ops)
                  (setq out (append out (list (concat "=== point " (conformance--where dir))))))
                (when (equal op "follow")
                  (setq out (append out (list (concat "=== line "
                                                      (buffer-substring-no-properties
                                                       (line-beginning-position)
                                                       (line-end-position))))))))
              (unless (member (car (split-string (car ops) " " t)) conformance--quiet-ops)
                (setq out (append out (list "=== buffer")
                                  (with-current-buffer buf (conformance--buffer-lines))))))))
        (dolist (u (reverse conformance--opens)) (setq out (append out (list (concat "=== open " u)))))
        (when (conformance--values header "PROMPTS")
          (setq out (append out (list "=== prompts")
                            (mapcar (lambda (p) (concat "? " (replace-regexp-in-string "\n" "\\\\n" p)))
                                    (reverse conformance--prompts)))))
        (let ((files (conformance--file-lines before (conformance--snapshot root))))
          (when files (setq out (append out (list "=== files") files))))
        (dolist (b (buffer-list))
          (when (or (and (buffer-file-name b)
                         (string-prefix-p (file-truename root) (file-truename (buffer-file-name b))))
                    (string-prefix-p "*Org" (buffer-name b)))
            (with-current-buffer b (set-buffer-modified-p nil))
            (kill-buffer b)))
        (delete-directory root t)
        (conformance--replace-dirs (concat (mapconcat #'identity out "\n") "\n") root dir)))))

(defun conformance--prompt (p)
  (push (substring-no-properties p) conformance--prompts)
  t)

(defun conformance--completing-read (_p coll &optional _pred _req init _hist def &rest _)
  (cond
   (conformance--cite-key
    (let ((key conformance--cite-key) found)
      (setq conformance--cite-key nil)
      (when (hash-table-p coll)
        (maphash (lambda (k v) (when (and (not found) (equal v key)) (setq found k))) coll))
      (or found "")))
   (conformance--link-answer
    (prog1 conformance--link-answer (setq conformance--link-answer nil)))
   ((hash-table-p coll) "")
   (t (or init (if (consp def) (car def) def) (caar org-stored-links) ""))))

(defun conformance--read-string (p &optional init _hist def &rest _)
  (cond
   ((and conformance--link-answer (string-match-p "Link" p))
    (prog1 conformance--link-answer (setq conformance--link-answer nil)))
   ((and conformance--desc-answer (string-match-p "Description" p))
    conformance--desc-answer)
   (t (or init (if (consp def) (car def) def) ""))))

(defun conformance-run (listfile outdir option)
  (let ((org-id-locations-file (make-temp-file "conformance-id-locations")))
    (cl-letf (((symbol-function 'yes-or-no-p) #'conformance--prompt)
              ((symbol-function 'y-or-n-p) #'conformance--prompt)
              ((symbol-function 'browse-url)
               (lambda (u &rest _) (push u conformance--opens)))
              ((symbol-function 'completing-read) #'conformance--completing-read)
              ((symbol-function 'completing-read-multiple)
               (lambda (&rest args)
                 (let ((r (apply #'conformance--completing-read args)))
                   (if (equal r "") nil (list r)))))
              ((symbol-function 'read-string) #'conformance--read-string))
      (dolist (file (split-string (with-temp-buffer
                                    (insert-file-contents listfile)
                                    (buffer-string))
                                  "\n" t))
        (let ((result (conformance--render file option)))
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region result nil
                          (expand-file-name (concat (file-name-nondirectory file) ".out") outdir)
                          nil 'silent)))))
    (delete-file org-id-locations-file)))
