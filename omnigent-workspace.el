;;; omnigent-workspace.el --- Workspace changes for Omnigent -*- lexical-binding: t; -*-

;;; Commentary:
;; Stateless workspace data operations.  Callbacks receive (STATUS BODY), as
;; in `omnigent-transport-request'.  Successful diffs are strings; successful
;; workspace listings contain `root', `paths', and `changes'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'omnigent-transport)

(defun omnigent-workspace--path (session-id suffix)
  "Return the environment resource path for SESSION-ID and SUFFIX."
  (omnigent-transport--session-path
   session-id (concat "/resources/environments/default/" suffix)))

(defun omnigent-workspace--changes (session-id callback)
  "Request changed paths for SESSION-ID and call CALLBACK with the response."
  (omnigent-transport-request
   "GET" (omnigent-workspace--path session-id "changes") callback))

(defun omnigent-workspace--paths (body)
  "Extract workspace-relative paths from changes response BODY."
  (let ((data (alist-get 'data body)))
    (unless (and (vectorp data)
                 (cl-every (lambda (entry) (stringp (alist-get 'path entry))) data))
      (error "Invalid workspace changes response"))
    (mapcar (lambda (entry) (alist-get 'path entry)) (append data nil))))

(defun omnigent-workspace--diff (path before after)
  "Generate a unified diff for PATH from BEFORE and AFTER text."
  (let ((old (make-temp-file "omnigent-before-"))
        (new nil))
    (unwind-protect
        (progn
          (setq new (make-temp-file "omnigent-after-"))
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file old (insert (or before "")))
            (with-temp-file new (insert (or after ""))))
          (with-temp-buffer
            (let ((status (call-process "diff" nil t nil "-u"
                                        "-L" (concat "a/" path)
                                        "-L" (concat "b/" path) old new)))
              (unless (memq status '(0 1))
                (error "diff failed: %s" (buffer-string)))
              (buffer-string))))
      (delete-file old)
      (when new (delete-file new)))))

(defun omnigent-workspace-file-diff (session-id path callback)
  "Fetch a unified diff for PATH in SESSION-ID and call CALLBACK.
CALLBACK receives (STATUS DIFF) on success, or (STATUS ERROR) on failure."
  (omnigent-transport-request
   "GET" (omnigent-workspace--path
          session-id (concat "diff/" (mapconcat #'url-hexify-string
                                                (split-string path "/") "/")))
   (lambda (status body)
     (if (not (omnigent-transport-success-p status))
         (funcall callback status body)
       (let ((result
              (condition-case err
                  (let ((before (alist-get 'before body))
                        (after (alist-get 'after body)))
                    (unless (and (listp body) (assq 'before body) (assq 'after body)
                                 (or (null before) (stringp before))
                                 (or (null after) (stringp after)))
                      (error "Invalid diff response for %s" path))
                    (omnigent-workspace--diff path before after))
                (error err))))
         (if (stringp result)
             (funcall callback status result)
           (funcall callback nil (error-message-string result))))))))

(defun omnigent-workspace-diff (session-id callback)
  "Fetch a unified workspace diff for SESSION-ID and call CALLBACK.
CALLBACK receives (STATUS DIFF) on success, or (STATUS ERROR) on failure.
The result is a best-effort view, not an atomic snapshot."
  (omnigent-workspace--changes
   session-id
   (lambda (status body)
     (if (not (omnigent-transport-success-p status))
         (funcall callback status body)
       (let ((paths (condition-case err
                        (omnigent-workspace--paths body)
                      (error err)))
             (patches nil))
         (if (and (consp paths) (eq (car paths) 'error))
             (funcall callback nil (error-message-string paths))
           (cl-labels
            ((next ()
               (if (null paths)
                   (funcall callback status (apply #'concat (nreverse patches)))
                 (let ((path (pop paths)))
                   (omnigent-workspace-file-diff
                    session-id path
                    (lambda (file-status result)
                      (if (not (omnigent-transport-success-p file-status))
                          (funcall callback file-status result)
                        (push result patches)
                        (next))))))))
            (next))))))))

(defun omnigent-workspace--root (session-id callback &optional attempt)
  "Fetch SESSION-ID's root, retrying a host-only listing before CALLBACK.
ATTEMPT counts retries while the runner starts; disconnect cancels retries."
  (let ((generation omnigent-transport--generation)
        (attempt (or attempt 0)))
    (omnigent-transport-request
     "GET" (omnigent-workspace--path session-id "filesystem")
     (lambda (status body)
       ;; ponytail: retry for five seconds; use a server readiness signal when available.
       (if (and (omnigent-transport-success-p status)
                (listp body) (equal (alist-get 'object body) "list")
                (not (assq 'base body)) (< attempt 10))
           (run-at-time 0.5 nil
                        (lambda ()
                          (when (= generation omnigent-transport--generation)
                            (omnigent-workspace--root session-id callback (1+ attempt)))))
         (funcall callback status body))))))

(defun omnigent-workspace-list (session-id callback)
  "Fetch the environment root and changed paths for SESSION-ID.
CALLBACK receives (STATUS ((root . ROOT) (paths . PATHS) (changes . CHANGES)))
on success, or (STATUS ERROR) on failure.  CHANGES contains alists with `path'
and `status' strings.  ROOT is a runner path, not a local filename."
  (omnigent-workspace--root
   session-id
   (lambda (status body)
     (if (not (omnigent-transport-success-p status))
         (funcall callback status body)
       (let ((root (and (listp body) (alist-get 'base body))))
         (if (not (and (stringp root) (file-name-absolute-p root)))
             (funcall callback nil "Invalid environment root response")
           (omnigent-workspace--changes
            session-id
            (lambda (changes-status changes-body)
              (if (not (omnigent-transport-success-p changes-status))
                  (funcall callback changes-status changes-body)
                (let ((paths (condition-case err
                                 (prog1 (omnigent-workspace--paths changes-body)
                                   (unless (cl-every
                                            (lambda (entry)
                                              (stringp (alist-get 'status entry)))
                                            (alist-get 'data changes-body))
                                     (error "Invalid workspace changes response")))
                               (error err))))
                  (if (and (consp paths) (eq (car paths) 'error))
                      (funcall callback nil (error-message-string paths))
                    (funcall callback changes-status
                             `((root . ,root) (paths . ,paths)
                               (changes . ,(mapcar
                                           (lambda (entry)
                                             `((path . ,(alist-get 'path entry))
                                               (status . ,(alist-get 'status entry))))
                                           (append (alist-get 'data changes-body) nil))))))))))))))))

(defun omnigent-workspace-local-filename (root path &optional mapping)
  "Return a filename for ROOT and relative PATH using trusted MAPPING.
MAPPING must be `local' for a known local runner, or a TRAMP prefix string
for a remote runner.  Signal an error when direct access is unavailable."
  (unless (and (stringp root) (file-name-absolute-p root)
               (not (file-remote-p root)) (stringp path)
               (not (file-name-absolute-p path))
               (not (member ".." (split-string path "/"))))
    (error "Invalid workspace root or relative path"))
  (unless (or (eq mapping 'local)
              (and (stringp mapping) (file-remote-p (concat mapping "/"))))
    (error "Direct workspace access is unavailable"))
  (concat (if (eq mapping 'local) "" mapping)
          (expand-file-name path (file-name-as-directory root))))

(provide 'omnigent-workspace)
;;; omnigent-workspace.el ends here
