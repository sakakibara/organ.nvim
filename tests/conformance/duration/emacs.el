;;; emacs.el --- Emacs side of the duration conformance gate  -*- lexical-binding: t -*-
;;;
;;; Each case line that is not blank or a `;' comment is one item, a
;;; form whose arguments are data, never evaluated (see NORMALIZE.md).
;;; Every item writes one line, in the shape organ.lua writes.  Before
;;; calling org-duration, the item's range condition is computed here in
;;; exact integer arithmetic; an item that crosses it prints
;;; "!! out of range" instead of Emacs's answer.

(require 'cl-lib)
(require 'org-duration)

(defconst conformance-duration-bound (expt 2 53))

(defun conformance-duration--text (file)
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8-unix))
      (insert-file-contents file))
    (buffer-string)))

(defun conformance-duration--int (n)
  "N, after throwing t to `conformance-duration' when N is an integer
of at least the bound."
  (when (and (integerp n) (>= n conformance-duration-bound))
    (throw 'conformance-duration t))
  n)

(defun conformance-duration--walk (d canonical)
  "Form the integers `org-duration-to-minutes' forms for D, in its
order, stopping where it would signal."
  (cond
   ((not (stringp d)) nil)
   ((equal d "") nil)
   ((string-match-p org-duration--h:mm-re d)
    (let ((parts (mapcar #'string-to-number (split-string d ":"))))
      (mapc #'conformance-duration--int parts)
      (conformance-duration--int (* 60 (car parts)))))
   ((string-match-p org-duration--full-re d)
    (let ((minutes 0)
          (s 0))
      (while (string-match org-duration--unit-re d s)
        (setq s (match-end 0))
        (let* ((value (conformance-duration--int
                       (string-to-number (match-string 1 d))))
               (modifier (cdr (assoc (match-string 2 d)
                                     (if canonical
                                         org-duration-canonical-units
                                       org-duration-units)))))
          (unless modifier
            (throw 'conformance-duration nil))
          (setq minutes (conformance-duration--int
                         (+ minutes (conformance-duration--int
                                     (* value modifier)))))))))
   ((string-match org-duration--mixed-re d)
    (let ((units (match-string 1 d))
          (hms (match-string 2 d)))
      (conformance-duration--walk units nil)
      (conformance-duration--walk hms nil)))
   ((string-match-p "\\`[0-9]+\\(\\.[0-9]*\\)?\\'" d)
    (conformance-duration--int (string-to-number d)))))

(defun conformance-duration--to-crosses-p (d canonical)
  (catch 'conformance-duration
    (conformance-duration--walk d canonical)
    nil))

(defun conformance-duration--from-crosses-p (m)
  "Whether |M| * 60 >= 2^53, exactly."
  (cond
   ((integerp m) (>= (* 60 (abs m)) conformance-duration-bound))
   ((or (isnan m) (= (abs m) 1.0e+INF)) t)
   (t (let* ((fe (frexp (abs m)))
             (mant (truncate (ldexp (car fe) 53)))
             (e (- (cdr fe) 53)))
        (if (>= e 0)
            (>= (* 60 mant (ash 1 e)) conformance-duration-bound)
          (>= (* 60 mant) (ash conformance-duration-bound (- e))))))))

(defun conformance-duration--value-line (value)
  (concat "=> " (let ((print-escape-newlines t))
                  (prin1-to-string value))))

(defun conformance-duration--call (fn)
  (condition-case err
      (conformance-duration--value-line (funcall fn))
    (error (concat "!! " (let ((print-escape-newlines t))
                           (prin1-to-string (error-message-string err)))))))

(defun conformance-duration--item (form)
  (pcase form
    (`(to-minutes ,d . ,rest)
     (if (conformance-duration--to-crosses-p d (car rest))
         "!! out of range"
       (conformance-duration--call
        (lambda () (org-duration-to-minutes d (car rest))))))
    (`(p ,s)
     (conformance-duration--call (lambda () (and (org-duration-p s) t))))
    (`(from-minutes ,m . ,rest)
     (if (conformance-duration--from-crosses-p m)
         "!! out of range"
       (conformance-duration--call
        (lambda () (org-duration-from-minutes m (car rest) (cadr rest))))))
    (`(h-mm-only-p ,times)
     (conformance-duration--call (lambda () (org-duration-h:mm-only-p times))))
    (_ (error "conformance: unknown item %S" form))))

(defun conformance-duration--render (file)
  (let (lines)
    (dolist (line (split-string (conformance-duration--text file) "\n"))
      (unless (or (string= line "") (string-prefix-p ";" line))
        (push (conformance-duration--item (car (read-from-string line))) lines)))
    (mapconcat (lambda (l) (concat l "\n")) (nreverse lines) "")))

(defun conformance-run (listfile outdir _option)
  (dolist (file (split-string (conformance-duration--text listfile) "\n" t))
    (let ((out (conformance-duration--render file))
          (coding-system-for-write 'utf-8-unix))
      (with-temp-file (expand-file-name
                       (concat (file-name-nondirectory file) ".out") outdir)
        (insert out)))))

;;; emacs.el ends here
