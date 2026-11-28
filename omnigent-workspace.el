;;; omnigent-workspace.el --- Workspace paths and patches -*- lexical-binding: t; -*-

;;; Commentary:
;; Map workspace paths, look up environment roots, and fetch workspace patches.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'url-parse)
(require 'omnigent-transport)

(defun omnigent-workspace-host-mapping (host-id)
  "Return the local marker or SSH prefix for HOST-ID."
  (unless (stringp host-id)
    (error "Workspace host ID is unavailable"))
  (let ((address (funcall omnigent-host-address-function host-id)))
    (unless (and (stringp address) (not (string-empty-p address)))
      (error "Invalid workspace host address"))
    (when (equal address "localhost")
      (setq address
            (url-host (url-generic-parse-url omnigent-server-url))))
    (if (member address '("localhost" "127.0.0.1" "::1" "[::1]"))
        'local
      (format "/ssh:%s:" address))))

(defun omnigent-workspace--path (session-id suffix)
  "Return the environment resource path for SESSION-ID and SUFFIX."
  (omnigent-transport--session-path
   session-id (concat "/resources/environments/default/" suffix)))

(defun omnigent-workspace--root
    (session-id callback &optional attempt)
  "Fetch SESSION-ID's root, retrying a host-only listing before CALLBACK.
ATTEMPT counts retries while the runner starts; disconnect cancels retries."
  (let ((generation omnigent-transport--generation)
        (attempt (or attempt 0)))
    (omnigent-transport--request
     session-id
     "GET"
     (omnigent-workspace--path session-id "filesystem")
     (lambda (status body)
       ;; ponytail: retry for five seconds; use a server readiness signal when available.
       (if (and (omnigent-transport-success-p status)
                (listp body)
                (equal (alist-get 'object body) "list")
                (not (assq 'base body))
                (< attempt 10))
           (run-at-time
            0.5 nil
            (lambda ()
              (when (= generation omnigent-transport--generation)
                (omnigent-workspace--root session-id callback
                                          (1+ attempt)))))
         (funcall callback status body))))))

(defun omnigent-workspace-local-filename (root path &optional mapping)
  "Return a filename for ROOT and relative PATH using trusted MAPPING.
MAPPING must be `local' for a known local runner, or a TRAMP prefix string
for a remote runner.  Signal an error when direct access is unavailable."
  (unless (and (stringp root)
               (file-name-absolute-p root)
               (not (file-remote-p root))
               (stringp path)
               (not (file-name-absolute-p path))
               (not (member ".." (split-string path "/"))))
    (error "Invalid workspace root or relative path"))
  (unless (or (eq mapping 'local)
              (and (stringp mapping)
                   (file-remote-p (concat mapping "/"))))
    (error "Direct workspace access is unavailable"))
  (concat
   (if (eq mapping 'local)
       ""
     mapping)
   (expand-file-name path (file-name-as-directory root))))

(defun omnigent-workspace--changes (session-id callback)
  "Request changed paths for SESSION-ID and call CALLBACK with the response."
  (omnigent-transport--request
   session-id
   "GET"
   (omnigent-workspace--path session-id "changes")
   callback))

(defun omnigent-workspace--paths (body)
  "Extract workspace-relative paths from changes response BODY."
  (let ((data (alist-get 'data body)))
    (unless (and (vectorp data)
                 (cl-every
                  (lambda (entry)
                    (stringp (alist-get 'path entry)))
                  data))
      (error "Invalid workspace changes response"))
    (mapcar
     (lambda (entry) (alist-get 'path entry)) (append data nil))))

(defun omnigent-workspace--diff (path before after)
  "Generate a unified diff for PATH from BEFORE and AFTER text."
  (let ((default-directory temporary-file-directory)
        (old (make-temp-file "omnigent-before-"))
        (new nil))
    (unwind-protect
        (progn
          (setq new (make-temp-file "omnigent-after-"))
          (let ((coding-system-for-write 'utf-8-unix))
            (with-temp-file old
              (insert (or before "")))
            (with-temp-file new
              (insert (or after ""))))
          (with-temp-buffer
            (let ((status
                   (call-process "diff"
                                 nil
                                 t
                                 nil
                                 "-u"
                                 "-L"
                                 (concat "a/" path)
                                 "-L"
                                 (concat "b/" path)
                                 old
                                 new)))
              (unless (memq status '(0 1))
                (error "diff failed: %s" (buffer-string)))
              (buffer-string))))
      (delete-file old)
      (when new
        (delete-file new)))))

(defun omnigent-workspace--file-diff (session-id path callback)
  "Fetch a unified diff for PATH in SESSION-ID and call CALLBACK.
CALLBACK receives (STATUS DIFF) on success, or (STATUS ERROR) on failure."
  (omnigent-transport--request
   session-id "GET"
   (omnigent-workspace--path
    session-id
    (concat
     "diff/"
     (mapconcat #'url-hexify-string (split-string path "/") "/")))
   (lambda (status body)
     (if (not (omnigent-transport-success-p status))
         (funcall callback status body)
       (let ((result
              (condition-case err
                  (let ((before (alist-get 'before body))
                        (after (alist-get 'after body)))
                    (unless (and (listp body)
                                 (assq 'before body)
                                 (assq 'after body)
                                 (or (null before) (stringp before))
                                 (or (null after) (stringp after)))
                      (error "Invalid diff response for %s" path))
                    (omnigent-workspace--diff path before after))
                (error
                 err))))
         (if (stringp result)
             (funcall callback status result)
           (funcall callback nil (error-message-string result))))))))

(defun omnigent-workspace--fetch-diff (session-id callback)
  "Fetch a unified workspace diff for SESSION-ID and call CALLBACK.
CALLBACK receives (STATUS DIFF) on success, or (STATUS ERROR) on failure.
The result is a best-effort view, not an atomic snapshot."
  (omnigent-workspace--changes
   session-id
   (lambda (status body)
     (if (not (omnigent-transport-success-p status))
         (funcall callback status body)
       (let ((paths
              (condition-case err
                  (omnigent-workspace--paths body)
                (error
                 err)))
             (patches nil))
         (if (and (consp paths) (eq (car paths) 'error))
             (funcall callback nil (error-message-string paths))
           (cl-labels
            ((next
              ()
              (if (null paths)
                  (funcall callback
                           status
                           (apply #'concat (nreverse patches)))
                (let ((path (pop paths)))
                  (omnigent-workspace--file-diff
                   session-id path
                   (lambda (file-status result)
                     (if (not
                          (omnigent-transport-success-p file-status))
                         (funcall callback file-status result)
                       (push result patches)
                       (next))))))))
            (next))))))))

(provide 'omnigent-workspace)
;;; omnigent-workspace.el ends here
