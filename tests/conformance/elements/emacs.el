;;; emacs.el --- Elements conformance gate: org-element side  -*- lexical-binding: t -*-
;;;
;;; Prints org-element's parse of each case, one line per element or
;;; object in document order (see NORMALIZE.md for the line format).  A
;;; case may hold several documents separated by lines of exactly
;;; "=====", each parsed on its own under a "##### N" header.

(load (expand-file-name "../_clock.el" (file-name-directory load-file-name)))
(conformance-clock-pin)

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-element)
(require 'org-inlinetask)

(setq org-element-use-cache nil)
(setq org-todo-keywords
      '((sequence "TODO" "NEXT" "WAITING" "HOLD" "PROJ" "|" "DONE" "CANCELLED")))

(defun conformance--esc (s)
  (replace-regexp-in-string
   "\n" "\\\\n"
   (replace-regexp-in-string "\t" "\\\\t" (replace-regexp-in-string "\\\\" "\\\\\\\\" s))))

(defun conformance--pos (pos)
  (save-excursion
    (goto-char pos)
    (format "%d:%d" (line-number-at-pos pos)
            (- (position-bytes pos) (position-bytes (line-beginning-position))))))

(defun conformance--trim-end (beg end)
  (while (and (> end beg) (memq (char-before end) '(?\s ?\t ?\n)))
    (setq end (1- end)))
  end)

(defun conformance--priority (p)
  (cond ((null p) nil)
        ((<= p 64) (number-to-string p))
        (t (char-to-string p))))

(defun conformance--checkbox (c)
  (pcase c ('on "on") ('off "off") ('trans "trans")))

(defun conformance--props (node)
  (let ((type (org-element-type node))
        (out '()))
    (cl-flet ((add (k v) (when (and v (not (equal v "")))
                           (push (format "%s=%s" k (conformance--esc v)) out))))
      (pcase type
        ((or 'headline 'inlinetask)
         (add "level" (number-to-string (org-element-property :level node)))
         (add "todo" (org-element-property :todo-keyword node))
         (add "priority" (conformance--priority (org-element-property :priority node)))
         (when (org-element-property :commentedp node) (add "commented" "t"))
         (add "tags" (mapconcat #'substring-no-properties
                                (org-element-property :tags node) ","))
         (add "title" (org-element-property :raw-value node)))
        ('planning
         (dolist (k '(:closed :deadline :scheduled))
           (let ((ts (org-element-property k node)))
             (when ts (add (substring (symbol-name k) 1)
                           (org-element-property :raw-value ts))))))
        ('clock (add "duration" (org-element-property :duration node)))
        ('node-property
         (add "key" (org-element-property :key node))
         (add "value" (org-element-property :value node)))
        ('drawer (add "name" (org-element-property :drawer-name node)))
        ('src-block (add "language" (org-element-property :language node)))
        ('export-block (add "type" (upcase (or (org-element-property :type node) ""))))
        ('special-block (add "type" (org-element-property :type node)))
        ('dynamic-block (add "name" (org-element-property :block-name node)))
        ('item
         (add "bullet" (string-trim (org-element-property :bullet node)))
         (let ((c (org-element-property :counter node)))
           (when c (add "counter" (format "%s" c))))
         (add "checkbox" (conformance--checkbox (org-element-property :checkbox node)))
         (let ((tag (org-element-property :tag node)))
           (when tag
             (add "tag" (string-trim (substring-no-properties
                                      (org-element-interpret-data tag)))))))
        ((or 'keyword 'babel-call)
         (add "key" (if (eq type 'babel-call) "CALL" (org-element-property :key node)))
         (add "value" (string-trim (or (org-element-property :value node) ""))))
        ('footnote-definition (add "label" (org-element-property :label node)))
        ('table
         (add "type" (symbol-name (org-element-property :type node)))
         (let ((f (org-element-property :tblfm node)))
           (when f (add "tblfm" (number-to-string (length f))))))
        ('table-row (add "type" (symbol-name (org-element-property :type node))))
        ('diary-sexp (add "value" (string-trim (org-element-property :value node))))
        ('timestamp (add "type" (symbol-name (org-element-property :type node)))))
      (when (memq type org-element-all-elements)
        (let ((aff '()))
          (dolist (k '("CAPTION" "HEADER" "NAME" "PLOT" "RESULTS"))
            (when (org-element-property (intern (concat ":" (downcase k))) node)
              (push k aff)))
          (cl-loop for (k _v) on (nth 1 node) by #'cddr
                   when (and (keywordp k) (string-prefix-p ":attr_" (symbol-name k)))
                   do (push (upcase (substring (symbol-name k) 1)) aff))
          (when aff (add "aff" (mapconcat #'identity (sort (delete-dups aff) #'string<) ","))))
        (let ((name (org-element-property :name node)))
          (when name (add "name" name)))))
    (nreverse out)))

(defvar conformance--records nil)
(defvar conformance--seq 0)

(defun conformance--record (node)
  (let* ((beg (if (memq (org-element-type node) org-element-all-elements)
                  (or (org-element-property :post-affiliated node)
                      (org-element-property :begin node))
                (org-element-property :begin node)))
         (end (conformance--trim-end beg (org-element-property :end node))))
    (when (eq (org-element-type node) 'citation-reference)
      (when (eq (char-before end) ?\;) (setq end (conformance--trim-end beg (1- end)))))
    (while (and (< beg end) (memq (char-after beg) '(?\s ?\t ?\n)))
      (setq beg (1+ beg)))
    (setq conformance--seq (1+ conformance--seq))
    (push (list beg end conformance--seq
                (mapconcat #'identity
                           (cons (format "%s %s-%s" (org-element-type node)
                                         (conformance--pos beg) (conformance--pos end))
                                 (conformance--props node))
                           " "))
          conformance--records)))

(defun conformance--walk (node)
  (unless (stringp node)
    (unless (eq (org-element-type node) 'org-data)
      (conformance--record node))
    (when (memq (org-element-type node) '(headline inlinetask))
      (mapc #'conformance--walk (org-element-property :title node)))
    (when (eq (org-element-type node) 'item)
      (mapc #'conformance--walk (org-element-property :tag node)))
    (dolist (caption (org-element-property :caption node))
      (mapc #'conformance--walk (if (consp (car caption)) (car caption) (list (car caption))))
      (when (consp (cdr caption)) (mapc #'conformance--walk (cdr caption))))
    (mapc #'conformance--walk (org-element-contents node))))

(defun conformance--file-id (tree)
  (let ((first (car (org-element-contents tree))))
    (when (eq (org-element-type first) 'section)
      (let ((drawer (seq-find (lambda (e) (eq (org-element-type e) 'property-drawer))
                              (org-element-contents first))))
        (when drawer
          (seq-some (lambda (p) (and (equal (upcase (org-element-property :key p)) "ID")
                                     (org-element-property :value p)))
                    (org-element-contents drawer)))))))

(defun conformance--dump (src)
  (with-temp-buffer
    (insert src)
    (let ((org-inhibit-startup t)) (org-mode))
    (setq conformance--records nil conformance--seq 0)
    (let ((tree (org-element-parse-buffer))
          (lines '()))
      (conformance--walk tree)
      (setq lines
            (mapcar #'cadddr
                    (sort conformance--records
                          (lambda (a b)
                            (cond ((/= (nth 0 a) (nth 0 b)) (< (nth 0 a) (nth 0 b)))
                                  ((/= (nth 1 a) (nth 1 b)) (> (nth 1 a) (nth 1 b)))
                                  (t (< (nth 2 a) (nth 2 b))))))))
      (org-element-map tree 'headline
        (lambda (h)
          (setq lines (append lines (list (mapconcat #'identity
                                                     (cons "entry" (conformance--props h))
                                                     " "))))))
      (let ((id (conformance--file-id tree)))
        (when id (setq lines (append lines (list (concat "file-id " (conformance--esc id)))))))
      (mapconcat (lambda (l) (concat l "\n")) lines ""))))

(defun conformance--documents (text)
  (if (string-match-p "\n=====\n" text)
      (split-string text "^=====\n" nil)
    (list text)))

(defun conformance-run (listfile outdir _option)
  (let ((cases (with-temp-buffer
                 (insert-file-contents listfile)
                 (split-string (buffer-string) "\n" t))))
    (dolist (case cases)
      (let* ((text (with-temp-buffer
                     (let ((coding-system-for-read 'utf-8))
                       (insert-file-contents case))
                     (buffer-string)))
             (docs (conformance--documents text))
             (multi (cdr docs))
             (i 0)
             (out ""))
        (dolist (doc docs)
          (setq i (1+ i))
          (setq out (concat out (if multi (format "##### %d\n" i) "")
                            (conformance--dump doc))))
        (let ((coding-system-for-write 'utf-8))
          (with-temp-file (expand-file-name (concat (file-name-nondirectory case) ".out") outdir)
            (insert out)))))))
