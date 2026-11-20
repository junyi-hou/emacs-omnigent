;;; omnigent-corfu.el --- Corfu refresh for Omnigent -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "29.1") (corfu "2.7"))

;;; Commentary:
;; Refresh file completion after an asynchronous directory listing.

;;; Code:

(defun omnigent-corfu-setup ()
  "Enable Corfu in the current conversation."
  (require 'corfu)
  (corfu-mode 1))

(defun omnigent-corfu-refresh (directory)
  "Refresh the Corfu menu for DIRECTORY when it is still active."
  (when (and (bound-and-true-p corfu-mode)
             (eq (current-buffer) (window-buffer (selected-window)))
             (fboundp 'corfu--exhibit))
    (let* ((context (omnigent--file-completion-context))
           (current (and context (nth 2 context))))
      (when (equal
             directory
             (if (equal current ".")
                 ""
               current))
        (if (bound-and-true-p completion-in-region-mode)
            (when (eq
                   (nth 2 completion-in-region--data)
                   #'omnigent--file-candidates)
              (setq corfu--input nil)
              (corfu--exhibit))
          (when (fboundp 'corfu--auto-complete-deferred)
            (corfu--auto-complete-deferred)))))))

(provide 'omnigent-corfu)
;;; omnigent-corfu.el ends here
