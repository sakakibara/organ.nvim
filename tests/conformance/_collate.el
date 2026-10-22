;;; _collate.el --- Sort strings as Emacs does on GNU/Linux  -*- lexical-binding: t -*-
;;;
;;; The gates run with LC_ALL=C.  There `string-collate-lessp', org's
;;; default `org-sort-function', folds ASCII case when asked to and then
;;; compares code points.  An Emacs built for macOS has no locale
;;; collation and falls back to `string-lessp', ignoring IGNORE-CASE (Org
;;; documents the macOS behaviour as inaccurate, debbugs#59275), so a
;;; case-insensitive org sort comes out case-sensitive.  On macOS org
;;; sorts with the C-locale behaviour instead, so every platform produces
;;; the same Emacs output.  Calls without IGNORE-CASE already agree.

(defun conformance--collate-lessp (s1 s2 &optional _locale ignore-case)
  (let ((a (if (symbolp s1) (symbol-name s1) s1))
        (b (if (symbolp s2) (symbol-name s2) s2))
        (case-fold-search nil))
    (when ignore-case
      (setq a (replace-regexp-in-string "[A-Z]" #'downcase a t t)
            b (replace-regexp-in-string "[A-Z]" #'downcase b t t)))
    (string-lessp a b)))

(when (eq system-type 'darwin)
  (setq org-sort-function #'conformance--collate-lessp))

;;; _collate.el ends here
