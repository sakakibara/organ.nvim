;;; emacs-agenda-snapshot.el --- Dump org-agenda output for parity diff
;;;
;;; Usage:
;;;   emacs --batch -Q -l scripts/emacs-agenda-snapshot.el \
;;;     --eval '(organ-snapshot "/path/to/org-dir" "2026-05-04" "week")'
;;;
;;; Prints the Emacs `org-agenda' buffer text to stdout.  Output is
;;; designed to be deterministic across hosts -- pins:
;;;   * `org-agenda-start-day' (which day the agenda window opens on)
;;;   * `org-today' via advice-override (used by the time-grid `today'
;;;     keyword, "Sched. Nx" repeater counter, and "In N d." deadline
;;;     countdown)
;;;   * `current-time' via cl-letf (belt-and-suspenders for any other
;;;     org-mode internals that consult it)
;;;   * `system-time-locale' = "C" (English weekday/month names so the
;;;     fixture text is identical regardless of host LC_TIME)
;;;   * TZ = "UTC" (so encode-time doesn't shift the calendar day on
;;;     hosts running in extreme timezones)
;;;
;;; That makes runs on different days, locales, and timezones produce
;;; byte-identical output for a given org fixture set + Emacs version.
;;; (Org-mode version differences across Emacs releases can still
;;; surface; regenerate the fixture if you bump Emacs.)
;;;
;;; Args:
;;;   org-dir   - directory containing .org files
;;;   today-iso - date the agenda is rendered FOR (e.g. "2026-05-04")
;;;   span      - "day" or "week"

(require 'cl-lib)
(require 'org)
(require 'org-agenda)

(defun organ-snapshot (org-dir today-iso span)
  "Render the Emacs org-agenda for ORG-DIR on TODAY-ISO with SPAN.
Prints the agenda buffer text to stdout."
  ;; Pin TZ + locale FIRST so encode-time and format-time-string (called
  ;; from inside org-agenda) produce host-independent output.  setenv on
  ;; TZ has to happen before encode-time below, and setting
  ;; `system-time-locale' globally is fine because batch Emacs exits
  ;; right after.
  (setenv "TZ" "UTC")
  (setq system-time-locale "C")
  ;; Pin "today" deterministically.  cl-letf on `current-time' alone is
  ;; not enough: `org-today' calls `(time-since N)' which expands to
  ;; `(time-subtract nil N)', and the nil-as-now sentinel is resolved
  ;; inside the C primitive without dispatching through the Lisp
  ;; `current-time' symbol.  So we also advice `org-today' directly to
  ;; return the pinned absolute day; that's what the time-grid `today'
  ;; keyword, "Sched. Nx" repeater counter, and "In N d." deadline
  ;; countdown all consult.
  (let* ((year  (string-to-number (substring today-iso 0 4)))
         (month (string-to-number (substring today-iso 5 7)))
         (day   (string-to-number (substring today-iso 8 10)))
         (pinned-time (encode-time 0 0 12 day month year))
         (pinned-absolute (calendar-absolute-from-gregorian (list month day year))))
    (advice-add 'org-today :override (lambda () pinned-absolute))
    (cl-letf (((symbol-function 'current-time) (lambda () pinned-time)))
      (let* ((org-agenda-files (directory-files org-dir t "\\.org\\'"))
             ;; Pin start-day so the agenda window doesn't shift.
             (org-agenda-start-day today-iso)
             (org-agenda-span (intern span))
             ;; Stable rendering options matching our defaults.
             (org-agenda-use-time-grid t)
             (org-agenda-time-grid '((daily today require-timed)
                                     (800 1000 1200 1400 1600 1800 2000)
                                     "......" "----------------"))
             ;; The "now" marker uses (format-time-string "%H:%M") with
             ;; no time argument, which reads the system clock at the C
             ;; level and bypasses any Lisp-level override.  Disable it
             ;; entirely so parity output is fully deterministic.  The
             ;; time grid itself (08:00, 10:00, ...) still renders.
             (org-agenda-show-current-time-in-grid nil)
             (org-agenda-window-setup 'current-window)
             (org-agenda-restore-windows-after-quit nil)
             (org-agenda-prefix-format
              '((agenda . " %i %-12:c%?-12t% s")
                (todo . " %i %-12:c")
                (tags . " %i %-12:c")
                (search . " %i %-12:c")))
             (org-agenda-include-diary nil))
        (org-agenda-list nil today-iso (intern span))
        (princ (with-current-buffer org-agenda-buffer-name
                 (buffer-substring-no-properties (point-min) (point-max))))
        (terpri)))))

;;; emacs-agenda-snapshot.el ends here
