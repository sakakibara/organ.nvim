;;; emacs.el --- Emacs side of the capture conformance gate  -*- lexical-binding: t -*-
;;;
;;; (conformance-run LISTFILE OUTDIR OPTION) copies each case's fixture
;;; files into a fresh work directory, runs the operation registered for
;;; the case (`cf-defop', keyed by the case basename), and writes
;;; OUTDIR/<basename>.out: the operation's report lines, then a dump of
;;; the files it names.  Paths under the work directory print as $WORK,
;;; and as ~$WORK where Emacs abbreviates them.  The case format, the
;;; operations and every setting are described in NORMALIZE.md.
;;;
;;; org-roam is loaded from CONFORMANCE_ORG_ROAM_PATH (colon-separated
;;; load-path entries); conformance-run signals an error when it is unset.

(load (expand-file-name "../_clock.el" (file-name-directory load-file-name)) nil t)
(conformance-clock-pin)

(require 'cl-lib)
(require 'subr-x)
(require 'org)
(require 'org-capture)
(require 'org-refile)
(require 'org-archive)
(require 'org-attach)
(require 'org-id)
(require 'org-clock)
(require 'org-datetree)
(require 'ox-publish)

(defconst cf-todo-keywords
  '((sequence "TODO" "NEXT" "WAITING" "HOLD" "PROJ" "|" "DONE" "CANCELLED")))

(defvar cf-root (file-name-as-directory
                 (file-truename (make-temp-file "conformance-capture" t))))

(setenv "HOME" (directory-file-name cf-root))
(setq abbreviated-home-dir nil
      system-time-locale "C"
      user-full-name "Test User"
      user-login-name "tester"
      org-todo-keywords cf-todo-keywords
      org-id-uuid-program "true"
      org-id-track-globally t
      org-agenda-files nil
      make-backup-files nil
      auto-save-default nil
      create-lockfiles nil
      org-bookmark-names-plist nil
      kill-buffer-query-functions nil)

(defvar cf-ops (make-hash-table :test 'equal))
(defvar cf-work nil)
(defvar cf-out nil)
(defvar cf-answers nil)

(defmacro cf-defop (name &rest body)
  "Register BODY as the operation of case NAME."
  (declare (indent 1))
  `(puthash ,name (lambda () ,@body) cf-ops))

;;; Reporting

(defun cf-msg (fmt &rest args)
  (push (concat (apply #'format fmt args) "\n") cf-out))

(defun cf-read (file)
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents file))
    (buffer-string)))

(defun cf-files (&optional dir)
  "Every file under DIR (default the work dir), sorted by path."
  (sort (directory-files-recursively (or dir cf-work) "" nil) #'string<))

(defun cf-dump (&optional files)
  "Save every buffer, then print FILES (default every file in the work dir)."
  (save-some-buffers t)
  (dolist (f (or files (cf-files)))
    (push (format "=== %s\n%s<<EOF>>\n" (file-relative-name f cf-work) (cf-read f)) cf-out)))

(defmacro cf-try (&rest body)
  "Run BODY, reporting an error instead of aborting."
  `(condition-case err (progn ,@body)
     (error (cf-msg "ERROR: %s" (error-message-string err)))))

(defun cf-shape (s)
  (let ((case-fold-search nil))
    (replace-regexp-in-string "[0-9a-f]" "h" (replace-regexp-in-string "[A-F]" "H" s t t) t t)))

;;; Prompts: answered in order from `cf-answers'

(defun cf--next () (or (pop cf-answers) ""))
(defun cf--or-default (a def)
  (if (and (equal a "") def) (if (consp def) (car def) def) a))
(advice-add 'read-string :override
            (lambda (_prompt &optional _init _hist def &rest _)
              (cf--or-default (cf--next) def)))
(advice-add 'read-from-minibuffer :override (lambda (&rest _) (cf--next)))
(advice-add 'completing-read :override
            (lambda (_prompt _coll &optional _pred _req _init _hist def &rest _)
              (cf--or-default (cf--next) def)))
(advice-add 'completing-read-multiple :override
            (lambda (&rest _) (split-string (cf--next) "[: ]+" t)))
(advice-add 'yes-or-no-p :override (lambda (_) (equal (cf--next) "yes")))
(advice-add 'y-or-n-p :override (lambda (_) (equal (cf--next) "y")))
(advice-add 'org-read-date :around
            (lambda (orig &optional with-time to-time from-string prompt &rest rest)
              (apply orig with-time to-time (or from-string (cf--next)) prompt rest)))

;;; Operation helpers

(defun cf-path (file) (expand-file-name file cf-work))

(defun cf-visit (file &optional search)
  "Visit FILE in the work dir; put point at the start of SEARCH's match."
  (find-file (cf-path file))
  (goto-char (point-min))
  (when search (re-search-forward search) (goto-char (match-beginning 0)))
  (current-buffer))

(defun cf-capture (key &optional text)
  "Run capture template KEY; insert TEXT at point, then finalize."
  (cf-try
   (org-capture nil key)
   (when (and (bound-and-true-p org-capture-mode) (buffer-base-buffer))
     (when text (insert text))
     (org-capture-finalize))))

(defun cf-line-at (file pos)
  (with-current-buffer (find-file-noselect file)
    (save-excursion
      (goto-char pos)
      (format "%s:%d %s" (file-relative-name file cf-work) (line-number-at-pos)
              (buffer-substring-no-properties (line-beginning-position) (line-end-position))))))

(defun cf-open (link)
  "Open LINK from a.org and report where point lands."
  (cf-try
   (find-file (cf-path "a.org"))
   (goto-char (point-max))
   (org-link-open-from-string link)
   (with-current-buffer (window-buffer (selected-window))
     (cf-msg "%s -> %s" link (cf-line-at (buffer-file-name) (point))))))

(defun cf-refile-labels ()
  "Refile targets as FILE:OUTLINE/TITLE, sorted."
  (sort (mapcar (lambda (tg)
                  (let ((file (nth 1 tg)) (pos (nth 3 tg)))
                    (if (not pos)
                        (format "%s:" (file-name-nondirectory file))
                      (with-current-buffer (find-file-noselect file)
                        (save-excursion
                          (goto-char pos)
                          (format "%s:%s" (file-name-nondirectory file)
                                  (mapconcat #'identity (org-get-outline-path t) "/")))))))
                (org-refile-get-targets))
        #'string<))

(defun cf-publish-listing ()
  "Every file in the work dir; .html files with their hrefs, sitemaps in full."
  (dolist (f (cf-files))
    (let ((rel (file-relative-name f cf-work)))
      (cond
       ((string-match-p "sitemap\\.org\\'" rel)
        (cf-msg "=== %s\n%s<<EOF>>" rel (cf-read f)))
       ((string-match-p "\\.html\\'" rel)
        (cf-msg "--- %s hrefs: %s" rel
                (with-temp-buffer
                  (insert (cf-read f))
                  (goto-char (point-min))
                  (let (hs)
                    (while (re-search-forward "href=\"\\([^\"#]*\\)" nil t)
                      (push (match-string 1) hs))
                    (mapconcat #'identity (nreverse hs) " ")))))
       (t (cf-msg "--- %s" rel))))))

(defun cf-roam-sync ()
  (require 'org-roam)
  (require 'org-roam-dailies)
  (setq org-roam-directory cf-work
        org-roam-db-location (expand-file-name "roam.db" (file-name-directory
                                                          (directory-file-name cf-work)))
        org-roam-dailies-directory "daily/"
        org-roam-db-update-on-save nil)
  (org-roam-db-sync))

;;; Capture: template types and placement

(cf-defop "capture-entry-file"
  (let ((org-capture-templates
         '(("a" "entry file" entry (file "notes.org") "* TODO %?\n  %U"))))
    (cf-capture "a" "Buy milk"))
  (cf-dump))

(cf-defop "capture-file-headline"
  (let ((org-capture-templates
         '(("a" "hl" entry (file+headline "a.org" "Tasks") "* TODO %?")
           ("b" "missing" entry (file+headline "b.org" "Inbox") "* TODO %?"))))
    (cf-capture "a" "first")
    (cf-capture "b" "second"))
  (cf-dump))

(cf-defop "capture-entry-without-star"
  (let ((org-capture-templates
         '(("a" "hl" entry (file+headline "a.org" "Tasks") "Note %?")
           ("b" "file" entry (file "a.org") "Loose %?"))))
    (cf-capture "a" "x")
    (cf-capture "b" "y"))
  (cf-dump))

(cf-defop "capture-relevel"
  (let ((org-capture-templates
         '(("a" "hl" entry (file+headline "a.org" "Tasks") "** Sub %?\n*** child")
           ("b" "file" entry (file "a.org") "*** Deep %?\n**** deeper"))))
    (cf-capture "a" "x")
    (cf-capture "b" "y"))
  (cf-dump))

(cf-defop "capture-prepend"
  (let ((org-capture-templates
         '(("a" "hl" entry (file+headline "a.org" "Tasks") "* NEW %?" :prepend t)
           ("b" "file" entry (file "b.org") "* TOP %?" :prepend t))))
    (cf-capture "a" "x")
    (cf-capture "b" "y"))
  (cf-dump))

(cf-defop "capture-types"
  (let ((org-capture-templates
         '(("p" "plain" plain (file+headline "pl.org" "Plain") "plain %?")
           ("i" "item" item (file+headline "li.org" "List") "item %?")
           ("c" "checkitem" checkitem (file+headline "ch.org" "Check") "- [ ] %?")
           ("t" "table" table-line (file+headline "ta.org" "Table") "| %? | z |")
           ("e" "item new list" item (file+headline "em.org" "Empty") "first %?"))))
    (dolist (k '("p" "i" "c" "t" "e")) (cf-capture k "X")))
  (cf-dump))

(cf-defop "capture-file-regexp"
  (let ((org-capture-templates
         '(("1" "entry, plain line" entry (file+regexp "e1.org" "marker") "* E1 %?")
           ("2" "entry, heading" entry (file+regexp "e2.org" "^\\* B") "* E2 %?")
           ("3" "plain" plain (file+regexp "p1.org" "marker") "P1 %?")
           ("4" "plain prepend" plain (file+regexp "p2.org" "marker") "P2 %?" :prepend t))))
    (dolist (k '("1" "2" "3" "4")) (cf-capture k "x")))
  (cf-dump))

(cf-defop "capture-file-olp"
  (let ((org-capture-templates
         '(("a" "olp" entry (file+olp "a.org" "Projects" "Tasks") "* NEW %?")
           ("b" "dup" entry (file+olp "dup.org" "Proj" "Dup") "* D %?")
           ("c" "missing" entry (file+olp "a.org" "Projects" "Nope") "* M %?"))))
    (cf-msg "-- olp")
    (cf-capture "a" "x")
    (cf-msg "-- duplicate olp")
    (cf-capture "b" "y")
    (cf-msg "-- missing olp")
    (cf-capture "c" "z"))
  (cf-dump))

(cf-defop "capture-empty-lines"
  (let ((org-capture-templates
         '(("a" "el" entry (file+headline "a.org" "Tasks") "* E %?" :empty-lines 1)
           ("c" "before2 after1" entry (file+headline "c.org" "Tasks") "* C %?"
            :empty-lines-before 2 :empty-lines-after 1))))
    (dolist (k '("a" "c")) (cf-capture k "x")))
  (cf-dump))

(cf-defop "capture-blank-separated-file"
  (let ((org-capture-templates '(("b" "auto blank" entry (file "blank.org") "* B %?"))))
    (cf-capture "b" "x"))
  (cf-dump))

(cf-defop "capture-template-whitespace"
  (let ((org-capture-templates
         '(("a" "ws" entry (file+headline "n.org" "Inbox") "\n\n* W %?\n\tTabbed\nTrail   \n\n\n")
           ("b" "no %?" entry (file+headline "n.org" "Inbox") "* NoCursor"))))
    (cf-capture "a" "x")
    (cf-capture "b" " tail"))
  (cf-dump))

(defun cf-find-b ()
  (goto-char (point-min))
  (re-search-forward "^\\* B")
  (forward-line 0))

(cf-defop "capture-targets"
  (org-id-update-id-locations (list (cf-path "id.org")))
  (let ((org-capture-templates
         '(("i" "id" entry (id "tgt-1") "* I %?")
           ("f" "file+function" entry (file+function "fn.org" cf-find-b) "* F %?")
           ("k" "clock" entry (clock) "* K %?"))))
    (cf-msg "-- id target")
    (cf-capture "i" "x")
    (cf-msg "-- file+function target")
    (cf-capture "f" "x")
    (cf-msg "-- clock target")
    (cf-visit "clk.org" "^\\* Clocked")
    (org-clock-in)
    (cf-capture "k" "x")
    (org-clock-out))
  (cf-dump))

(cf-defop "capture-missing-directory"
  (let ((org-capture-templates
         '(("n" "nonexistent dir" entry (file "sub/new.org") "* N %?"))))
    (cf-capture "n" "x"))
  (cf-dump))

(cf-defop "capture-template-properties"
  (let ((org-capture-templates
         '(("i" "immediate" entry (file+headline "n.org" "Inbox") "* IMM done" :immediate-finish t)
           ("c" "clock-in" entry (file+headline "n.org" "Inbox") "* CLK %?" :clock-in t)
           ("j" "jump" entry (file+headline "n.org" "Inbox") "* JMP %?" :jump-to-captured t))))
    (cf-try (org-capture nil "i"))
    (cf-msg "capture buffer open after immediate-finish: %s"
            (if (bound-and-true-p org-capture-mode) "yes" "no"))
    (when (bound-and-true-p org-capture-mode) (org-capture-kill))
    (cf-try (org-capture nil "c")
            (insert "x")
            (cf-msg "clocking during capture: %s" (if (org-clocking-p) "yes" "no"))
            (org-capture-finalize))
    (when (org-clocking-p) (org-clock-out))
    (cf-try (org-capture nil "j")
            (insert "x")
            (org-capture-finalize)
            (cf-msg "after finalize: buffer=%s line=%s" (buffer-name)
                    (buffer-substring-no-properties (line-beginning-position)
                                                    (line-end-position)))))
  (cf-dump))

;;; Capture: %-escapes

(cf-defop "capture-escapes-basic"
  (let ((org-capture-templates
         '(("a" "esc" entry (file+headline "n.org" "Inbox")
            "* E %?\nn=%n\nt=%t\npct=%%\nT=%T\nesc=\\%t\nu=%u\nU=%U\nlt=%<%Y/%m %H>\nf=%f\nF=%F\nx=%x\nc=%c\nunknown=%q %z"))))
    (kill-new "KILLED")
    (cf-visit "src.org" "some body")
    (cf-capture "a" "1"))
  (cf-dump))

(cf-defop "capture-escapes-annotation"
  (let ((org-capture-templates
         '(("a" "annotation" entry (file+headline "n.org" "Inbox") "* A %?\na=%a")
           ("b" "link forms" entry (file+headline "links.org" "Inbox")
            "* B %?\nl=%l\nL=%L\nA=%A\nkw=%:file|%:link|%:description"))))
    (cf-visit "src.org" "some body")
    (cf-capture "a" "body")
    (cf-visit "src.org" "^\\* Source")
    (cf-capture "a" "heading")
    (cf-visit "src.org" "id body")
    (cf-capture "a" "id")
    (setq cf-answers '("DESC"))
    (cf-visit "src.org" "some body")
    (cf-capture "b" "links"))
  (cf-dump))

(cf-defop "capture-escapes-clock-file-sexp"
  (let ((org-capture-templates
         `(("a" "misc" entry (file+headline "n.org" "Inbox")
            ,(concat "* M %?\nk=%k\nK=%K\ninc=%[" (cf-path "inc.txt")
                     "]\nsexp=%(number-to-string (+ 1 2))\n  > %i\n")))))
    (cf-visit "src.org" "^\\* Clocked")
    (org-clock-in)
    (cf-visit "src.org" "region line one")
    (transient-mark-mode 1)
    (push-mark (point) t t)
    (forward-line 2)
    (cf-capture "a" "x")
    (org-clock-out))
  (cf-dump))

(cf-defop "capture-escapes-prompts"
  (let ((org-capture-templates
         '(("g" "tags" entry (file+headline "n.org" "Inbox") "* G %? %^g")
           ("p" "pick" entry (file+headline "n.org" "Inbox") "* PICK %?\npick=%^{Pick|dflt|c1|c2}")
           ("n" "back-reference" entry (file+headline "n.org" "Inbox")
            "* NAME %?\nname=%^{Name}\nback=%\\1")
           ("w" "typed date" entry (file+headline "n.org" "Inbox") "* WHEN %?\nwhen=%^{When}t")
           ("d" "date prompts" entry (file+headline "n.org" "Inbox")
            "* DATES %?\nt=%^t\nT=%^T\nu=%^u\nU=%^U")
           ("c" "G C L" entry (file+headline "n.org" "Inbox") "* GCL %?\nG=%^G\nC=%^C\nL=%^L")
           ("e" "property" entry (file+headline "n.org" "Inbox") "* PROP %?\n%^{Effort}p"))))
    (kill-new "KILLTEXT")
    (dolist (run '(("g" "work:home")
                   ("d" "+1d" "2026-05-06 9:15" "fri" "2026-05-07 10:00-11:30")
                   ("p" "")
                   ("n" "Alice")
                   ("w" "2026-05-10")
                   ("c" "x" "KILLTEXT" "KILLTEXT")
                   ("e" "1:30")))
      (setq cf-answers (cdr run))
      (cf-capture (car run) "body")))
  (cf-dump))

;;; Capture: datetree

(cf-defop "capture-datetree"
  (let ((org-capture-templates
         '(("a" "new" entry (file+olp+datetree "new.org") "* %?")
           ("b" "existing" entry (file+olp+datetree "j.org") "* %?")
           ("c" "under olp" entry (file+olp+datetree "p.org" "Journal") "* %?")
           ("d" "again same day" entry (file+olp+datetree "j.org") "* %?"))))
    (cf-capture "a" "one")
    (cf-capture "b" "two")
    (cf-capture "c" "three")
    (cf-capture "d" "four"))
  (cf-dump))

(cf-defop "capture-datetree-existing"
  (let ((org-capture-templates
         '(("p" "prop" entry (file+olp+datetree "prop.org") "* %?")
           ("l" "loc" entry (file+olp+datetree "loc.org") "* %?")
           ("t" "todo" entry (file+olp+datetree "todo.org") "* %?"))))
    (cf-capture "p" "P")
    (cf-capture "l" "L")
    (cf-capture "t" "T"))
  (cf-dump))

(cf-defop "capture-datetree-week-month"
  (let ((org-capture-templates
         '(("w" "week" entry (file+olp+datetree "w.org") "* %?" :tree-type week)
           ("m" "month" entry (file+olp+datetree "m.org") "* %?" :tree-type month))))
    (cf-capture "w" "wk")
    (cf-capture "m" "mo"))
  (cf-dump))

(cf-defop "capture-datetree-tree-types"
  (let ((org-capture-templates
         '(("q" "quarter" entry (file+olp+datetree "q.org") "* %?" :tree-type (year quarter month))
           ("p" "time-prompt" entry (file+olp+datetree "p.org") "* %? %U" :time-prompt t)
           ("s" "stamp" entry (file+olp+datetree "s.org") "* %?"))))
    (cf-capture "q" "Q")
    (setq cf-answers '("2026-02-14"))
    (cf-capture "p" "P")
    (let ((org-datetree-add-timestamp 'inactive))
      (cf-capture "s" "S")))
  (cf-dump))

;;; Refile

(defun cf-refile-to (answer &optional copy)
  (setq cf-answers (list answer))
  (cf-visit "src.org" "Move me")
  (cf-try (if copy (org-refile-copy) (org-refile))
          (run-hooks 'post-command-hook)))

(cf-defop "refile-default-targets"
  (cf-visit "src.org" "Move me")
  (let ((org-refile-targets nil) (org-refile-use-outline-path t))
    (dolist (l (cf-refile-labels)) (cf-msg "%s" l))))

(cf-defop "refile-targets"
  (cf-visit "src.org" "Move me")
  (let ((org-refile-use-outline-path t))
    (cf-msg "-- current file, maxlevel 2")
    (let ((org-refile-targets '((nil :maxlevel . 2))))
      (dolist (l (cf-refile-labels)) (cf-msg "%s" l)))
    (cf-msg "-- tgt.org level 1, current file level 3")
    (let ((org-refile-targets `((,(cf-path "tgt.org") :level . 1) (nil :level . 3))))
      (dolist (l (cf-refile-labels)) (cf-msg "%s" l)))
    (cf-msg "-- tag t, keyword TODO, regexp Alp")
    (let ((org-refile-targets '((nil :tag . "t") (nil :todo . "TODO") (nil :regexp . "Alp"))))
      (dolist (l (cf-refile-labels)) (cf-msg "%s" l)))))

(cf-defop "refile-move"
  (let ((org-refile-targets `((,(cf-path "tgt.org") :maxlevel . 3))))
    (cf-refile-to "Target"))
  (cf-dump))

(cf-defop "refile-copy"
  (let ((org-refile-targets `((,(cf-path "tgt.org") :maxlevel . 3))))
    (cf-refile-to "Target" t))
  (cf-dump))

(cf-defop "refile-same-file"
  (let ((org-refile-targets '((nil :maxlevel . 3))))
    (cf-refile-to "Alpha")
    (setq cf-answers '("Projects"))
    (cf-visit "src.org" "^\\* Done")
    (cf-try (org-refile)))
  (cf-dump))

(cf-defop "refile-top-level"
  (let ((org-refile-targets `((,(cf-path "tgt.org") :maxlevel . 3)))
        (org-refile-use-outline-path 'file))
    (cf-refile-to "tgt.org"))
  (cf-dump))

(cf-defop "refile-create-parent"
  (let ((org-refile-targets `((,(cf-path "tgt.org") :maxlevel . 3)))
        (org-refile-use-outline-path 'file)
        (org-refile-allow-creating-parent-nodes 'confirm))
    (setq cf-answers '("tgt.org/Target/New Parent" "y"))
    (cf-visit "src.org" "Move me")
    (cf-try (org-refile)))
  (cf-dump))

(cf-defop "refile-reverse-order"
  (let ((org-refile-targets `((,(cf-path "tgt.org") :maxlevel . 3)))
        (org-reverse-note-order t))
    (cf-refile-to "Target"))
  (cf-dump))

(cf-defop "refile-log"
  (let ((org-refile-targets `((,(cf-path "tgt.org") :maxlevel . 3)))
        (org-log-refile 'time)
        (org-log-into-drawer t))
    (cf-refile-to "Target"))
  (cf-dump))

;;; Archive

(defun cf-archive (file search &optional location)
  (cf-visit file search)
  (let ((org-archive-location (or location org-archive-location)))
    (cf-try (org-archive-subtree))))

(cf-defop "archive-default"
  (dolist (s '("Child task" "Sibling" "Top level")) (cf-archive "src.org" s))
  (cf-dump))

(cf-defop "archive-heading-location"
  (cf-archive "src.org" "Child task" "old.org::* Old Stuff")
  (cf-dump))

(cf-defop "archive-level-2-heading"
  (cf-archive "src.org" "Sibling" "lvl2.org::** Deep Archive")
  (cf-dump))

(cf-defop "archive-missing-directory"
  (cf-archive "src.org" "Top level" "arch/%s::")
  (cf-dump))

(cf-defop "archive-in-file"
  (cf-archive "src.org" "Child task" "::* Archive")
  (cf-dump))

(cf-defop "archive-keyword-after-line-50"
  (cf-archive "late.org" "^\\* Entry")
  (cf-dump))

(cf-defop "archive-keyword-first-wins"
  (cf-archive "multi.org" "^\\* Entry")
  (cf-dump))

(cf-defop "archive-inherited-property"
  (cf-archive "inherit.org" "Child")
  (cf-dump))

(cf-defop "archive-mark-done"
  (let ((org-archive-mark-done t)) (cf-archive "src.org" "Child task"))
  (cf-dump))

(cf-defop "archive-all-done"
  (setq cf-answers '("y" "y" "y"))
  (cf-visit "src.org" "^\\* A")
  (cf-try (org-archive-subtree '(4)))
  (cf-dump))

(cf-defop "archive-reversed-order"
  (let ((org-archive-reversed-order t))
    (cf-archive "src.org" "d1")
    (cf-archive "src.org" "d2"))
  (cf-dump))

(cf-defop "archive-location-without-colons"
  (cf-archive "src.org" "d1" "no-colons.org")
  (cf-dump))

(cf-defop "archive-sibling"
  (dolist (s '("Child task" "Sibling" "Other"))
    (cf-visit "src.org" s)
    (cf-try (org-archive-to-archive-sibling)))
  (cf-dump))

(cf-defop "archive-tag-toggle"
  (cf-visit "src.org" "Child task")
  (dotimes (i 2)
    (cf-try (org-toggle-archive-tag))
    (cf-msg "after toggle %d: %s" (1+ i)
            (buffer-substring-no-properties (line-beginning-position) (line-end-position))))
  (cf-dump))

(cf-defop "archive-datetree"
  (cf-archive "src.org" "Child task" "%s_archive::datetree/")
  (cf-dump))

;;; Attach

(cf-defop "attach-id-layouts"
  (dolist (p '("UUID heading" "TS heading" "Short heading" "Dir heading" "Child no id"))
    (cf-visit "a.org" p)
    (cf-try (org-attach-attach (cf-path "file.txt") nil 'cp)
            (cf-msg "%s: dir=%s" p (file-relative-name (org-attach-dir) cf-work))))
  (cf-visit "a.org" "UUID heading")
  (cf-msg "attachment:file.txt -> %s" (file-relative-name (org-attach-expand "file.txt") cf-work))
  (cf-dump))

(cf-defop "attach-existing-dirs"
  (dolist (p '("TS heading" "Short"))
    (cf-visit "a.org" p)
    (cf-try (cf-msg "%s: existing dir=%s" p (file-relative-name (org-attach-dir) cf-work)))
    (cf-try (cf-msg "%s: attachment:old.txt -> %s" p
                    (file-relative-name (org-attach-expand "old.txt") cf-work)))))

;;; org-id

(cf-defop "id-create"
  (cf-visit "a.org" "Plain heading")
  (let ((id (org-id-get-create)))
    (cf-msg "-- uuid\n%s version %s" (cf-shape id) (substring id 14 15)))
  (cf-visit "a.org" "Planned heading")
  (cf-try (org-id-get-create))
  (cf-visit "a.org" "With drawer")
  (cf-try (org-id-get-create))
  (cf-visit "a.org" "Intro")
  (cf-try (org-id-get-create))
  (let ((org-id-method 'ts))
    (let ((id (org-id-new)))
      (cf-msg "-- ts method\n%s%s" (substring id 0 15)
              (replace-regexp-in-string "[0-9]" "d" (substring id 15)))))
  (let ((org-id-method 'org))
    (cf-msg "-- org method")
    (cf-try (cf-msg "%s" (cf-shape (org-id-new)))))
  (let ((org-id-prefix "pfx"))
    (let ((id (org-id-new)))
      (cf-msg "-- prefix\n%s" (if (string-match "\\`[^:]*:" id)
                                 (concat (match-string 0 id) (cf-shape (substring id (match-end 0))))
                               (cf-shape id)))))
  (cf-dump))

(cf-defop "id-duplicate"
  (cf-msg "-- index")
  (org-id-update-id-locations (list (cf-path "d.org")))
  (cf-msg "-- lookup")
  (dolist (id '("same-id" "file-level-id"))
    (let ((m (org-id-find id)))
      (cf-msg "%s -> %s" id (if m (cf-line-at (car m) (cdr m)) "nil"))))
  (cf-msg "-- file-level attach")
  (cf-visit "d.org")
  (cf-try (org-attach-attach (cf-path "file.txt") nil 'cp)
          (cf-msg "dir=%s" (file-relative-name (org-attach-dir) cf-work)))
  (cf-dump))

(cf-defop "id-links-locations"
  (setq org-id-locations-file (cf-path "id-locations"))
  (org-id-update-id-locations (directory-files-recursively cf-work "\\.org\\'"))
  (org-id-locations-save)
  (dolist (l '("[[id:aaa-111]]" "[[id:aaa-111::*Sub two]]" "[[id:file-b]]" "[[id:dup-1]]"
               "[[id:missing-1]]"))
    (cf-open l))
  (cf-dump))

;;; org-roam

(cf-defop "roam-nodes"
  (cf-roam-sync)
  (cf-msg "-- nodes")
  (dolist (r (org-roam-db-query [:select [id level title] :from nodes :order-by id]))
    (cf-msg "node %s\n  level %s\n  title %s" (nth 0 r) (nth 1 r) (nth 2 r)))
  (cf-msg "-- aliases")
  (dolist (r (org-roam-db-query [:select [node-id alias] :from aliases :order-by [node-id alias]]))
    (cf-msg "%s %s" (nth 0 r) (nth 1 r)))
  (cf-msg "-- refs")
  (dolist (r (org-roam-db-query [:select [node-id type ref] :from refs :order-by [node-id ref]]))
    (cf-msg "%s %s:%s" (nth 0 r) (nth 1 r) (nth 2 r)))
  (cf-msg "-- id links (source -> target)")
  (dolist (r (sort (mapcar (lambda (r) (format "%s -> %s" (nth 0 r) (nth 1 r)))
                           (org-roam-db-query [:select [source dest] :from links
                                               :where (= type "id")]))
                   #'string<))
    (cf-msg "%s" r))
  (cf-msg "-- org-id lookup")
  (org-id-update-id-locations (directory-files cf-work t "\\.org\\'"))
  (dolist (id '("n1" "n2" "id-three"))
    (let ((m (org-id-find id)))
      (cf-msg "%s -> %s" id (if m (cf-line-at (car m) (cdr m)) "nil")))))

(cf-defop "roam-create-node"
  (let ((org-id-method 'uuid))
    (cf-roam-sync)
    (cf-try (org-roam-capture- :node (org-roam-node-create :title "My First Note")
                               :props '(:immediate-finish t)))
    (cf-try (org-roam-dailies-capture-today)
            (insert "daily entry")
            (org-capture-finalize)))
  (cf-msg "-- slugs")
  (dolist (s (split-string (cf-read (cf-path "slugs.txt")) "\n" t))
    (cf-msg "\"%s\" -> \"%s\"" s (org-roam-node-slug (org-roam-node-create :title s))))
  (cf-dump (cl-remove-if (lambda (f) (string-suffix-p "/slugs.txt" f)) (cf-files))))

(cf-defop "roam-daily-existing"
  (cf-roam-sync)
  (cf-try (org-roam-dailies-capture-today) (insert "second") (org-capture-finalize))
  (cf-dump))

(cf-defop "roam-links"
  (cf-roam-sync)
  (dolist (l '("[[roam:Note One]]" "[[roam:Alias One]]"))
    (cf-try
     (find-file (cf-path "l.org"))
     (org-link-open-from-string l)
     (with-current-buffer (window-buffer (selected-window))
       (cf-msg "%s -> %s" l (cf-line-at (buffer-file-name) (point)))))))

;;; Publish

(defun cf-publish-setup ()
  (setq org-publish-timestamp-directory
        (expand-file-name "timestamps/" (file-name-directory (directory-file-name cf-work)))
        org-publish-cache nil
        org-export-with-toc nil
        org-html-validation-link nil))

(defmacro cf-unpinned (&rest body)
  "Run BODY on the real clock: org-publish compares file times with it."
  `(let ((fns '(current-time format-time-string decode-time float-time current-time-string
                time-convert time-less-p time-equal-p time-subtract time-add org-today)))
     (dolist (f fns) (advice-mapc (lambda (a _) (advice-remove f a)) f))
     (unwind-protect (progn ,@body)
       (dolist (f fns) (advice-mapc (lambda (a _) (advice-remove f a)) f))
       (conformance-clock-pin))))

(cf-defop "publish-recursive-sitemap"
  (cf-publish-setup)
  (let ((org-publish-project-alist
         `(("flat" :base-directory ,(cf-path "src")
            :publishing-directory ,(cf-path "pub-flat")
            :publishing-function org-html-publish-to-html)
           ("full" :base-directory ,(cf-path "src")
            :publishing-directory ,(cf-path "pub-full")
            :recursive t :exclude "draft" :auto-sitemap t
            :publishing-function org-html-publish-to-html))))
    (cf-unpinned
     (cf-try (org-publish "flat"))
     (cf-try (org-publish "full"))
     (cf-publish-listing)
     (with-temp-file (cf-path "pub-flat/index.html") (insert "STALE"))
     (cf-try (org-publish "flat")))
    (cf-msg "after re-publish, pub-flat/index.html starts: %s"
            (substring (cf-read (cf-path "pub-flat/index.html")) 0 5))))

(cf-defop "publish-exclude"
  (cf-publish-setup)
  (dolist (ex '("^draft" "draft\\.org" "old.draft"))
    (cf-msg "exclude %s -> %s" ex
            (mapconcat #'identity
                       (sort (mapcar #'file-name-nondirectory
                                     (org-publish-get-base-files
                                      (list "p" :base-directory (cf-path "src") :exclude ex
                                            :publishing-directory (cf-path "pub"))))
                             #'string<)
                       " "))))

(cf-defop "publish-components"
  (cf-publish-setup)
  (let ((org-publish-project-alist
         `(("idx" :base-directory ,(cf-path "src")
            :publishing-directory ,(cf-path "pub")
            :makeindex t :include ("extra.txt")
            :publishing-function org-html-publish-to-html)
           ("static" :base-directory ,(cf-path "src") :base-extension "css"
            :publishing-directory ,(cf-path "pub")
            :publishing-function org-publish-attachment)
           ("site" :components ("idx" "static")))))
    (cf-try (org-publish "site")))
  (dolist (f (cf-files)) (cf-msg "%s" (file-relative-name f cf-work))))

;;; Driver

(defun cf--parse-case (file)
  "Return (HEADER . FILES): HEADER an alist of (KEY . VALUE), FILES (NAME . TEXT)."
  (let ((lines (split-string (cf-read file) "\n"))
        (header '()) (files '()) (name nil) (body '()))
    (when (equal (car (last lines)) "")
      (setq lines (butlast lines)))
    (dolist (line lines)
      (cond
       ((string-match "\\`#\\+CONFORMANCE-FILE: \\(.+\\)\\'" line)
        (when name (push (cons name (nreverse body)) files))
        (setq name (match-string 1 line) body '()))
       ((and (null name)
             (string-match "\\`#\\+CONFORMANCE-\\([A-Z]+\\): \\(.*\\)\\'" line))
        (push (cons (match-string 1 line) (match-string 2 line)) header))
       (name (push line body))))
    (when name (push (cons name (nreverse body)) files))
    (cons (nreverse header)
          (mapcar (lambda (f)
                    (cons (car f) (if (cdr f) (concat (mapconcat #'identity (cdr f) "\n") "\n") "")))
                  (nreverse files)))))

(defun cf--values (header key)
  (delq nil (mapcar (lambda (h) (and (equal (car h) key) (cdr h))) header)))

(defun cf--reset ()
  "Drop the state one case leaves behind."
  (when (org-clocking-p) (org-clock-out nil t))
  (dolist (b (buffer-list))
    (unless (member (buffer-name b) '("*scratch*" "*Messages*"))
      (with-current-buffer b (set-buffer-modified-p nil))
      (kill-buffer b)))
  (when (fboundp 'org-roam-db--close-all) (org-roam-db--close-all))
  (setq org-id-locations nil
        org-id-files nil
        org-stored-links nil
        kill-ring nil
        kill-ring-yank-pointer nil
        cf-answers nil
        org-publish-cache nil)
  (transient-mark-mode -1))

(defun cf--paths (text)
  (let ((dir (directory-file-name cf-work)))
    (string-replace (abbreviate-file-name dir) "~$WORK" (string-replace dir "$WORK" text))))

(defun cf--render (case-file option)
  (let* ((parsed (cf--parse-case case-file))
         (header (car parsed))
         (name (file-name-sans-extension (file-name-nondirectory case-file)))
         (options (split-string (or (car (cf--values header "OPTIONS")) "") " " t))
         (op (gethash name cf-ops)))
    (if (and option (not (member option options)))
        (format "(not in the %s run)\n" option)
      (let ((case-dir (file-name-as-directory (expand-file-name name cf-root))))
        (setq cf-work (file-name-as-directory (expand-file-name "work" case-dir))
              cf-out nil
              org-id-locations-file (expand-file-name "id-locations" case-dir)
              org-directory cf-work
              org-default-notes-file (cf-path "notes.org")
              default-directory cf-work)
        (make-directory cf-work t)
        (dolist (d (cf--values header "DIR")) (make-directory (cf-path d) t))
        (dolist (f (cdr parsed))
          (let ((path (cf-path (car f))))
            (make-directory (file-name-directory path) t)
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (cdr f) nil path nil 'silent))))
        (if op
            (condition-case err (funcall op)
              (error (cf-msg "CASE-ERROR: %s" (error-message-string err))))
          (cf-msg "CASE-ERROR: no operation for %s" name))
        (let ((text (cf--paths (apply #'concat (nreverse cf-out)))))
          (cf--reset)
          (setq default-directory cf-root)
          text)))))

(defun cf--roam-last (cases)
  "CASES with the roam-* cases moved to the end.
Loading org-roam rebinds the `id' link type, so it loads only once every
other case has run."
  (let ((roam (cl-remove-if-not
               (lambda (c) (string-prefix-p "roam-" (file-name-nondirectory c))) cases)))
    (append (cl-set-difference cases roam :test #'equal) roam)))

(defun conformance-run (listfile outdir option)
  (let ((path (getenv "CONFORMANCE_ORG_ROAM_PATH")))
    (unless (and path (not (string-empty-p path)))
      (error "CONFORMANCE_ORG_ROAM_PATH is unset: set it to the org-roam load-path entries (colon-separated)"))
    (dolist (d (reverse (split-string path ":" t)))
      (add-to-list 'load-path (expand-file-name d)))
    (unless (locate-library "org-roam")
      (error "CONFORMANCE_ORG_ROAM_PATH does not provide org-roam: %s" path)))
  (dolist (case-file (cf--roam-last (with-temp-buffer
                                      (insert-file-contents listfile)
                                      (split-string (buffer-string) "\n" t))))
    (let ((text (cf--render case-file option)))
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region text nil (expand-file-name
                                (concat (file-name-nondirectory case-file) ".out") outdir)
                      nil 'silent))))
  (delete-directory cf-root t))
