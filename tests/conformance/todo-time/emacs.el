;;; emacs.el --- Emacs side of the todo-time conformance gate  -*- lexical-binding: t -*-
;;;
;;; Each case is an org file whose `#+CONFORMANCE-KEY: VALUE' header lines
;;; name the operations to run and the settings to run them with (see
;;; NORMALIZE.md).  The rest of the case is written to a fresh directory as
;;; t.org (plus any `#+CONFORMANCE-FILE: NAME' sections), t.org is visited
;;; with point at the `<CURSOR>' marker, the operations run in order, and
;;; the buffer is printed, followed by a `--- log' section holding refusals
;;; and the lines the operations print.  tests/conformance/todo-time/
;;; organ.lua prints the same shape.

(load (expand-file-name "../_clock.el" (file-name-directory load-file-name)))
(conformance-clock-pin)
(set-terminal-coding-system 'utf-8)
(setq system-time-locale "C")
(require 'org)
(require 'org-clock)
(require 'org-colview)
(require 'org-timer)
(require 'org-duration)
(require 'cl-lib)

;; org.el declares these without a value, so they are special only there.
(defvar org-time-was-given)
(defvar org-end-time-was-given)

(defvar conformance--log nil)
(defvar conformance--inputs nil)
(defvar conformance--keys nil)
(defvar conformance--refused nil)
(defvar conformance--date-default nil)

(defun conformance--log (fmt &rest args)
  (push (apply #'format fmt args) conformance--log))

(defun conformance--pop-input ()
  (if conformance--inputs (pop conformance--inputs) ""))

(defun conformance--lines (text)
  (split-string (if (string-suffix-p "\n" text) (substring text 0 -1) text) "\n"))

(defun conformance--parse (text)
  "Split TEXT into (HEADER . FILES); HEADER is a list of (KEY . VALUE)."
  (let ((header nil) (files nil) (current nil) (in-header t))
    (dolist (line (conformance--lines text))
      (cond
       ((string-match "\\`#\\+CONFORMANCE-FILE: \\(.+\\)\\'" line)
        (setq in-header nil)
        (when current (push current files))
        (setq current (list (match-string 1 line))))
       ((and in-header (string-match "\\`#\\+CONFORMANCE-\\([A-Z]+\\): ?\\(.*\\)\\'" line))
        (push (cons (match-string 1 line) (match-string 2 line)) header))
       (t
        (setq in-header nil)
        (unless current (setq current (list "t.org")))
        (setcdr current (append (cdr current) (list line))))))
    (when current (push current files))
    (cons (nreverse header) (nreverse files))))

(defun conformance--values (header key)
  (delq nil (mapcar (lambda (h) (and (equal (car h) key) (cdr h))) header)))

(defun conformance--flush-note ()
  "Complete a log note `org-add-log-setup' left for the command loop."
  (when (memq 'org-add-log-note post-command-hook)
    (let ((this-command org-log-note-this-command))
      (org-add-log-note))
    (when (equal (buffer-name) "*Org Note*")
      (goto-char (point-max))
      (insert (conformance--pop-input))
      (org-store-log-note))))

(defun conformance--fmt-number (x)
  (if (and (numberp x) (= x (ftruncate x))) (format "%d" (truncate x)) (format "%s" x)))

(defun conformance--columns (global)
  (org-columns global)
  (let ((rows (make-hash-table)))
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'org-columns-key)
        (push (cons (overlay-start ov) ov)
              (gethash (line-number-at-pos (overlay-start ov)) rows))))
    (let (lines)
      (maphash (lambda (k _) (push k lines)) rows)
      (dolist (ln (sort lines #'<))
        (let ((ovs (mapcar #'cdr (sort (gethash ln rows) (lambda (a b) (< (car a) (car b)))))))
          (conformance--log
           "L%d: %s" ln
           (mapconcat (lambda (ov)
                        (format "%s=%S" (upcase (overlay-get ov 'org-columns-key))
                                (substring-no-properties
                                 (or (overlay-get ov 'org-columns-value-modified) ""))))
                      ovs "  "))))))
  (org-columns-quit))

(defun conformance--read-date (input)
  (let* ((org-time-was-given nil)
         (org-end-time-was-given nil)
         (tm (org-read-date nil t input nil conformance--date-default)))
    (conformance--log "read-date %s -> %s%s%s" (if (equal input "") "<EMPTY>" input)
                      (format-time-string "%Y-%m-%d %a %H:%M" tm)
                      (if org-time-was-given " T" " -")
                      (if org-end-time-was-given (concat " end=" org-end-time-was-given) ""))))

(defun conformance--op (op arg)
  (pcase op
    ("cycle" (let ((this-command 'org-todo) (last-command 'next-line)) (org-todo)))
    ("cycle-repeat" (let ((this-command 'org-todo) (last-command 'org-todo)) (org-todo)))
    ("right" (org-todo 'right))
    ("left" (org-todo 'left))
    ("todo" (org-todo (if (equal arg "none") 'none arg)))
    ("priority" (org-priority (string-to-char arg)))
    ("note" (org-add-note))
    ("goto"
     (goto-char (point-min))
     (search-forward arg)
     (goto-char (match-beginning 0)))
    ("at"
     (let ((l (string-to-number (car (split-string arg ":"))))
           (c (string-to-number (cadr (split-string arg ":")))))
       (goto-char (point-min))
       (forward-line (1- l))
       (forward-char c)))
    ("adv" (setq conformance-clock--now
                 (time-add conformance-clock--now (seconds-to-time (string-to-number arg)))))
    ("clock-in" (org-clock-in))
    ("clock-out" (org-clock-out))
    ("clock-cancel" (org-clock-cancel))
    ("clocking?" (conformance--log "clocking=%s" (if (org-clocking-p) "t" "nil")))
    ("modified?" (conformance--log "modified=%s" (if (buffer-modified-p) "t" "nil")))
    ("schedule" (org-schedule nil arg))
    ("deadline" (org-deadline nil arg))
    ("schedule-prompt" (call-interactively #'org-schedule))
    ("up" (org-timestamp-up (and arg (string-to-number arg))))
    ("down" (org-timestamp-down (and arg (string-to-number arg))))
    ("eval-range" (org-evaluate-time-range t))
    ("update-dblock" (org-update-dblock))
    ("update-all-dblocks" (org-update-all-dblocks))
    ("clock-report" (org-clock-report))
    ("set-effort" (call-interactively #'org-set-effort))
    ("columns" (conformance--columns nil))
    ("columns-global" (conformance--columns t))
    ("duration"
     (conformance--log "duration %S -> %s" arg
                       (condition-case nil
                           (conformance--fmt-number (org-duration-to-minutes arg))
                         (error "invalid"))))
    ("read-date" (conformance--read-date (if (equal arg "<EMPTY>") "" arg)))
    ("timer"
     (org-timer-set-timer)
     (conformance--log "timer=%s"
                       (if org-timer-countdown-timer
                           (round (float-time (time-subtract org-timer-start-time
                                                             conformance-clock--now)))
                         "none"))
     (when org-timer-countdown-timer (org-timer-stop)))
    (_ (error "conformance: unknown op %s" op))))

(defun conformance--run-op (spec buf)
  (let* ((op (car (split-string spec " ")))
         (arg (and (string-match " \\(.*\\)\\'" spec) (match-string 1 spec)))
         (conformance--refused nil))
    (cl-letf* ((orig-message (symbol-function 'message))
               ((symbol-function 'message)
                (lambda (fmt &rest args)
                  (when (and fmt (string-match-p "state change from .* blocked"
                                                 (apply #'format fmt args)))
                    (setq conformance--refused t))
                  (apply orig-message fmt args))))
      (condition-case nil
          (conformance--op op arg)
        (error (setq conformance--refused t)))
      ;; The command loop runs post-command-hook after a failed command too.
      (condition-case nil
          (conformance--flush-note)
        (error (setq conformance--refused t))))
    (when conformance--refused (conformance--log "! refused"))
    (when (buffer-live-p buf)
      (let ((p (with-current-buffer buf (point))))
        (set-buffer buf)
        (goto-char p)))))

(defun conformance--strip-cursor (lines)
  "Remove the <CURSOR> marker from LINES; return (LINES LINE COL) or (LINES nil nil)."
  (let ((n 0) (pos nil) (out nil))
    (dolist (l lines)
      (setq n (1+ n))
      (if (and (not pos) (string-match "<CURSOR>" l))
          (progn (setq pos (list n (match-beginning 0)))
                 (push (replace-match "" t t l) out))
        (push l out)))
    (cons (nreverse out) pos)))

(defun conformance--render (file option)
  (let* ((parsed (conformance--parse
                  (with-temp-buffer
                    (let ((coding-system-for-read 'utf-8)) (insert-file-contents file))
                    (buffer-string))))
         (header (car parsed))
         (files (cdr parsed))
         (options (split-string (or (car (conformance--values header "OPTIONS")) "") " " t)))
    (if (and option (not (member option options)))
        (format "(not in the %s run)\n" option)
      (let* ((dir (file-name-as-directory (make-temp-file "conformance-td" t)))
             (bindings (mapcar (lambda (s) (car (read-from-string s)))
                               (conformance--values header "EMACS")))
             (saved (mapcar (lambda (b) (cons (car b) (default-value (car b)))) bindings))
             (now (or (car (conformance--values header "NOW")) "2026-05-04 09:30"))
             (cursor nil) (paths nil) (out nil))
        (setq conformance--log nil
              conformance--inputs (conformance--values header "INPUT")
              conformance--keys (string-to-list
                                 (or (car (conformance--values header "KEYS")) ""))
              conformance--date-default
              (let ((d (car (conformance--values header "DEFAULT"))))
                (and d (conformance-clock--parse d)))
              conformance-clock--now (conformance-clock--parse now))
        (dolist (f files)
          (let* ((stripped (conformance--strip-cursor (cdr f)))
                 (path (expand-file-name (car f) dir)))
            (when (and (cdr stripped) (not cursor)) (setq cursor (cdr stripped)))
            (with-temp-file path
              (insert (mapconcat #'identity (car stripped) "\n") "\n"))
            (push path paths)))
        (setq paths (nreverse paths))
        (unwind-protect
            (progn
              (dolist (b bindings) (set-default (car b) (eval (cadr b) t)))
              (setq org-agenda-files paths)
              (let ((buf (find-file-noselect (car paths))))
                (switch-to-buffer buf)
                (goto-char (point-min))
                (when cursor
                  (forward-line (1- (car cursor)))
                  (forward-char (cadr cursor)))
                (dolist (spec (conformance--values header "OP"))
                  (conformance--run-op spec buf))
                (with-current-buffer buf
                  (let ((text (buffer-substring-no-properties (point-min) (point-max))))
                    (setq out (if (string-suffix-p "\n" text) text (concat text "\n")))))))
          (when (org-clocking-p)
            (move-marker org-clock-marker nil)
            (move-marker org-clock-hd-marker nil))
          (setq org-clock-history nil)
          (when org-timer-countdown-timer (cancel-timer org-timer-countdown-timer))
          (setq org-timer-countdown-timer nil org-timer-start-time nil)
          (remove-hook 'post-command-hook 'org-add-log-note)
          (setq org-log-setup nil)
          (dolist (b (buffer-list))
            (when (buffer-file-name b)
              (with-current-buffer b (set-buffer-modified-p nil))
              (kill-buffer b)))
          (dolist (s saved) (set-default (car s) (cdr s)))
          (delete-directory dir t))
        (when conformance--log
          (setq out (concat out "--- log\n"
                            (mapconcat #'identity (reverse conformance--log) "\n") "\n")))
        (let ((case-fold-search nil))
          (dolist (d (list (file-truename dir) dir))
            (setq out (replace-regexp-in-string (regexp-quote d) "<DIR>/" out t t))))
        out))))

(defun conformance-run (listfile outdir option)
  (setq org-read-date-popup-calendar nil)
  (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
            ((symbol-function 'y-or-n-p) (lambda (&rest _) t))
            ((symbol-function 'read-string)
             (lambda (&rest _) (conformance--pop-input)))
            ((symbol-function 'read-from-minibuffer)
             (lambda (&rest _) (conformance--pop-input)))
            ((symbol-function 'read-number)
             (lambda (&rest _) (string-to-number (conformance--pop-input))))
            ((symbol-function 'completing-read)
             (lambda (_prompt coll &rest _)
               (let ((items (delq nil (mapcar (lambda (c) (if (consp c) (car c) c))
                                              (if (functionp coll) nil coll)))))
                 (when items
                   (conformance--log "? choices: %s" (mapconcat #'identity items " "))))
               (conformance--pop-input)))
            ((symbol-function 'read-char-exclusive)
             (lambda (&rest _) (if conformance--keys (pop conformance--keys) ?q))))
    (dolist (file (conformance--lines
                   (with-temp-buffer (insert-file-contents listfile) (buffer-string))))
      (let ((out (let ((inhibit-message t))
                   (condition-case err (conformance--render file option)
                     (error (format "HARNESS-ERROR: %s\n" (error-message-string err))))))
            (coding-system-for-write 'utf-8-unix))
        (with-temp-file (expand-file-name (concat (file-name-nondirectory file) ".out") outdir)
          (insert out))))))
