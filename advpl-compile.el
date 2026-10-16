;;; advpl-compile.el --- Compile ADVPL/TLPP with the TOTVS CLI -*- lexical-binding: t; -*-
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: languages, tools
;; URL: https://github.com/phellipw/emacs-advpl-compile
;; Works with Doom Emacs but does not depend on Doom internals.
;;; Code:
(require 'cl-lib)
(require 'json)
(require 'compile)
(require 'subr-x)

(defgroup advpl-compile nil "Compile ADVPL/TLPP sources against an AppServer." :group 'tools)

(defcustom advpl-compile-command nil
  "CLI executable or argv prefix.  Nil finds advpls in PATH or Neovim Mason.
Neither this setting nor process arguments must contain credentials."
  :type '(choice (const nil) string (repeat string)))
(defcustom advpl-compile-temp-directory nil
  "Directory for private INI files; nil uses `temporary-file-directory'."
  :type '(choice (const nil) directory))
(defvar advpl-compile-profile nil
  "Session-only profile name or directory; overrides the Neovim profile.")
(defvar advpl-compile--last nil)
(defvar advpl-compile--process nil)
(defvar advpl-compile--log-buffer nil)

(defconst advpl-compile--extensions "\\.\\(prw\\|prx\\|tlpp\\|ch\\|aph\\|apw\\|apl\\)\\'")
(defconst advpl-compile--markers
  '(".advpl-build.json" ".advpl-build.local.json" ".advpl-lsp.json"
    ".tdscli.json" ".tdscli.ini" "appserver.ini" ".git"))

(defun advpl-compile--read-json (path)
  "Return JSON object at PATH as an alist; missing files are empty."
  (when (file-exists-p path)
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents path)
          (json-parse-buffer :object-type 'alist :array-type 'list
                             :null-object nil :false-object :json-false))
      (error (user-error "Cannot parse AdvPL JSON at %s (details suppressed)" path)))))

(defun advpl-compile--merge (left right)
  "Merge alists LEFT and RIGHT recursively, with RIGHT winning."
  (let ((result (copy-tree left)))
    (dolist (pair right result)
      (let ((old (alist-get (car pair) result)))
        (setf (alist-get (car pair) result)
              (if (and (consp old) (consp (cdr pair))
                       (consp (car old)) (consp (cadr pair)))
                  (advpl-compile--merge old (cdr pair))
                (cdr pair)))))))

(defun advpl-compile--first (&rest values)
  (cl-find-if (lambda (value) (and value (not (equal value "")))) values))

(defun advpl-compile--root (&optional file)
  "Find the closest AdvPL project marker above FILE or the current buffer."
  (let ((dir (file-name-directory (expand-file-name (or file buffer-file-name default-directory)))))
    (or (locate-dominating-file
         dir (lambda (parent)
               (cl-some (lambda (marker) (file-exists-p (expand-file-name marker parent)))
                        advpl-compile--markers)))
        dir)))

(defun advpl-compile--profile-spec (project)
  "Find the Neovim-compatible profile selected by PROJECT."
  (or advpl-compile-profile (getenv "ADVPL_PROFILE")
      (alist-get 'profile project)
      (alist-get 'profile
                 (advpl-compile--read-json
                  (expand-file-name "nvim/advpl/profile.json"
                                    (or (getenv "XDG_STATE_HOME")
                                        (expand-file-name "~/.local/state")))))))

(defun advpl-compile--profile-config (project)
  (when-let* ((spec (advpl-compile--profile-spec project))
              (dir (if (or (file-name-absolute-p spec)
                           (string-prefix-p "~" spec)
                           (string-match-p "[/\\\\]" spec)
                           (string-prefix-p "." spec))
                       (expand-file-name spec)
                     (expand-file-name
                      (concat "advpl/" spec)
                      (or (getenv "XDG_CONFIG_HOME") (expand-file-name "~/.config"))))))
    (cl-reduce #'advpl-compile--merge
               (mapcar (lambda (file) (advpl-compile--read-json (expand-file-name file dir)))
                       '("build.json" ".advpl-build.json" "local.json" ".advpl-build.local.json"))
               :initial-value nil)))

(defun advpl-compile--list (value)
  "Parse an array or semicolon-delimited VALUE, ignoring blank elements."
  (cl-remove-if #'string-empty-p
                (mapcar #'string-trim
                        (if (listp value) value (split-string (or value "") ";" t)))))

(defun advpl-compile--paths (root value)
  (delete-dups (mapcar (lambda (path) (expand-file-name path root))
                       (advpl-compile--list value))))

(defun advpl-compile--true (value &optional default)
  (cond ((null value) default)
        ((eq value :json-false) nil)
        ((stringp value) (member (downcase value) '("1" "true" "t" "yes" "y")))
        (t (not (equal value 0)))))

(defun advpl-compile--config (root)
  "Read the Neovim project/profile compile settings for ROOT.
Environment overrides profile; a selected profile overrides project unless
useProjectOverrides is true.  No credentials are displayed or persisted."
  (let* ((project (advpl-compile--merge
                   (advpl-compile--read-json (expand-file-name ".advpl-build.json" root))
                   (advpl-compile--read-json (expand-file-name ".advpl-build.local.json" root))))
         (lsp (advpl-compile--read-json (expand-file-name ".advpl-lsp.json" root)))
         (profile (advpl-compile--profile-config project))
         (project-first (advpl-compile--true
                         (advpl-compile--first (getenv "ADVPL_USE_PROJECT_OVERRIDES")
                                               (alist-get 'useProjectOverrides project)
                                               (alist-get 'use_project_overrides project))))
         (raw (if (and profile (not project-first))
                  (advpl-compile--merge project profile)
                (advpl-compile--merge profile project)))
         (effective-root (expand-file-name
                          (or (advpl-compile--first (getenv "ADVPL_PROJECT_ROOT")
                                                     (alist-get 'projectRoot raw)
                                                     (alist-get 'project_root raw)
                                                     (alist-get 'workspaceRoot raw)) ".") root))
         (connection (alist-get 'connection raw))
         (credentials (alist-get 'credentials raw))
         (authorization (alist-get 'authorization raw))
         (lsp-includes (advpl-compile--first (alist-get 'includes lsp) (alist-get 'includeDirs lsp)))
         (build-includes (advpl-compile--first (alist-get 'includes raw) (alist-get 'includeDirs raw)))
         (includes (delete-dups
                    (append (advpl-compile--paths effective-root
                                                  (getenv "ADVPL_INCLUDE_DIRS"))
                            (advpl-compile--paths effective-root lsp-includes)
                            (advpl-compile--paths effective-root build-includes)
                            (advpl-compile--paths effective-root
                                                  (getenv "ADVPL_COMPILE_INCLUDE_DIRS")))))
         (source-roots (advpl-compile--first (alist-get 'sourceRoots raw)
                                                   (alist-get 'source_roots raw) '("src"))))
    `((root . ,effective-root)
      (server . ,(advpl-compile--first (getenv "ADVPL_SERVER") (alist-get 'server raw)
                                        (alist-get 'server connection)))
      (port . ,(advpl-compile--first (getenv "ADVPL_PORT") (alist-get 'port raw)
                                      (alist-get 'port connection)))
      (secure . ,(advpl-compile--first (getenv "ADVPL_SECURE") (alist-get 'secure raw)
                                        (alist-get 'secure connection) 0))
      (build . ,(advpl-compile--first (getenv "ADVPL_BUILD") (alist-get 'build raw)
                                       (alist-get 'build connection) "AUTO"))
      (environment . ,(advpl-compile--first (getenv "ADVPL_ENVIRONMENT")
                                             (alist-get 'environment raw)
                                             (alist-get 'environment connection)))
      (user . ,(advpl-compile--first (getenv "ADVPL_USER") (alist-get 'user raw)
                                      (alist-get 'user credentials)))
      (password . ,(advpl-compile--first (getenv "ADVPL_PASSWORD") (getenv "ADVPL_PSW")
                                          (alist-get 'password raw) (alist-get 'psw raw)
                                          (alist-get 'password credentials) (alist-get 'psw credentials)))
      (authtoken . ,(advpl-compile--first (getenv "ADVPL_AUTHTOKEN") (alist-get 'authtoken raw)
                                           (alist-get 'authtoken authorization)))
      (authorization . ,(advpl-compile--first (getenv "ADVPL_AUTHORIZATION")
                                               (alist-get 'authorizationPath raw)
                                               (and (stringp authorization) authorization)
                                               (alist-get 'path authorization)))
      (includes . ,includes)
      (source-roots . ,(advpl-compile--paths effective-root source-roots))
      (recompile . ,(advpl-compile--true (advpl-compile--first (getenv "ADVPL_RECOMPILE")
                                                               (alist-get 'recompile raw)) t))
      (script-encoding . ,(advpl-compile--first (getenv "ADVPL_SCRIPT_ENCODING")
                                                 (alist-get 'scriptEncoding raw)
                                                 (alist-get 'script_encoding raw) "cp1252")))))

(defun advpl-compile--source-p (path)
  (let ((case-fold-search t)) (string-match-p advpl-compile--extensions path)))

(defun advpl-compile--files (files)
  "Normalize source FILES, omitting missing or empty files (CLI aborts batches)."
  (sort (delete-dups (cl-remove-if-not
                      (lambda (file) (and (advpl-compile--source-p file)
                                          (file-regular-p file) (> (file-attribute-size
                                                                     (file-attributes file)) 0)))
                      (mapcar #'expand-file-name files))) #'string<))

(defun advpl-compile--project-files (config)
  (advpl-compile--files
   (cl-mapcan (lambda (dir)
                (when (file-directory-p dir)
                  (directory-files-recursively dir advpl-compile--extensions nil nil t)))
              (alist-get 'source-roots config))))

(defun advpl-compile--git-output (root &rest args)
  "Read NUL-separated Git file names without a shell."
  (with-temp-buffer
    (let ((coding-system-for-read 'binary))
      (unless (eq 0 (apply #'process-file "git" nil (current-buffer) nil "-C" root args))
        (user-error "Git is unavailable or this is not a Git repository")))
    (split-string (buffer-string) "\0" t)))

(defun advpl-compile--changed-files (root)
  (let* ((top (string-trim
               (with-temp-buffer
                 (unless (eq 0 (process-file "git" nil (current-buffer) nil
                                             "-C" root "rev-parse" "--show-toplevel"))
                   (user-error "Not a Git repository"))
                 (buffer-string))))
         (names (append (advpl-compile--git-output top "diff" "--name-only" "-z"
                                                  "--diff-filter=ACMRTUXB")
                        (advpl-compile--git-output top "diff" "--cached" "--name-only" "-z"
                                                  "--diff-filter=ACMRTUXB")
                        (advpl-compile--git-output top "ls-files" "--others"
                                                  "--exclude-standard" "-z"))))
    (advpl-compile--files (mapcar (lambda (file) (expand-file-name file top)) names))))

(defun advpl-compile--checked (value &optional delimiter)
  "Reject INI injection and ambiguous DELIMITER in VALUE."
  (let ((text (format "%s" (or value ""))))
    (when (or (string-match-p "[\r\n]" text)
              (and delimiter (string-match-p (regexp-quote delimiter) text)))
      (user-error "Invalid newline or separator in AdvPL compile input"))
    text))

(defun advpl-compile--ini (config files)
  "Construct the CLI INI; never write this string to an ordinary buffer."
  (let ((required '(server port environment user password)))
    (dolist (field required)
      (unless (advpl-compile--first (alist-get field config))
        (user-error "Missing AdvPL %s (use environment or ignored local config)" field)))
    (let ((lines (list "action=authentication" "[authentication]" "" "showConsoleOutput=true")))
      (dolist (field '(server port secure build environment user password))
        (push (format "%s=%s" (if (eq field 'password) "psw" field)
                      (advpl-compile--checked (alist-get field config))) lines))
      (when (or (alist-get 'authtoken config) (alist-get 'authorization config))
        (push "" lines)
        (push "[authorization]" lines)
        (push "action=authorization" lines)
        (dolist (field '(authtoken authorization))
          (when-let* ((value (alist-get field config)))
            (push (format "%s=%s" field (advpl-compile--checked value)) lines))))
      (push "" lines)
      (push "[compile]" lines)
      (push "action=compile" lines)
      (push (concat "program=" (mapconcat
                                (lambda (path) (advpl-compile--checked path ",")) files ",")) lines)
      (push (concat "recompile=" (if (alist-get 'recompile config) "T" "F")) lines)
      (push (concat "includes=" (mapconcat
                                 (lambda (path) (advpl-compile--checked path ";"))
                                 (alist-get 'includes config) ";")) lines)
      (concat (mapconcat #'identity (nreverse lines) "\n") "\n"))))

(defun advpl-compile--encode (text encoding)
  "Encode TEXT as ENCODING, refusing lossy conversions."
  (let* ((coding (if (member (downcase encoding) '("cp1252" "windows-1252"))
                     'windows-1252 (or (ignore-errors (intern encoding)) 'windows-1252)))
         (bytes (encode-coding-string text coding t)))
    (unless (equal text (decode-coding-string bytes coding t))
      (user-error "AdvPL INI contains characters not representable in %s" encoding))
    bytes))

(defun advpl-compile--redact (text config)
  "Remove passwords/tokens from TEXT before displaying it anywhere."
  (let ((result text)
        (case-fold-search t))
    (dolist (value (list (alist-get 'password config) (alist-get 'authtoken config)
                         (alist-get 'authorization config)))
      (when (and (stringp value) (not (string-empty-p value)))
        (setq result (replace-regexp-in-string (regexp-quote value) "***" result t t))))
    (replace-regexp-in-string
     "\\b\\(psw\\|password\\|senha\\|token\\|authtoken\\|authorization\\)[[:space:]]*[:=][[:space:]]*[^;\r\n]+"
     "\\1=***" result t)))

(defun advpl-compile--command ()
  (let* ((data-home (or (getenv "XDG_DATA_HOME") (expand-file-name "~/.local/share")))
         (platform (pcase system-type
                     ('darwin "mac") ('windows-nt "windows") (_ "linux")))
         (executable (if (eq system-type 'windows-nt) "advpls.exe" "advpls"))
         (mason (expand-file-name (concat "nvim/mason/bin/" executable) data-home))
         (package (expand-file-name
                   (format "nvim/mason/packages/tds-ls/node_modules/@totvs/tds-ls/bin/%s/%s"
                           platform executable)
                   data-home))
         (candidate (or advpl-compile-command
                        (executable-find "advpls")
                        (and (file-executable-p mason) mason)
                        (and (file-executable-p package) package)))
         (argv (if (listp candidate) candidate (and candidate (list candidate)))))
    (unless (and argv (or (file-executable-p (car argv))
                          (executable-find (car argv))))
      (user-error "advpls not found; set advpl-compile-command or install TDS-LS"))
    argv))

(defun advpl-compile--write-ini (config ini)
  (let* ((temporary-file-directory (or advpl-compile-temp-directory temporary-file-directory))
         (path (make-temp-file "advpl-compile-" nil ".ini"))
         (complete nil))
    (unwind-protect
        (progn
          (let ((coding-system-for-write 'no-conversion))
            (with-temp-file path
              (set-buffer-multibyte nil)
              (insert (advpl-compile--encode ini (alist-get 'script-encoding config)))))
          (set-file-modes path #o600)
          (setq complete t)
          path)
      (unless complete (when (file-exists-p path) (delete-file path))))))

(defconst advpl-compile--error-regexps
  '((advpl-paren "\\([^ \t\n]+\\.\\(?:prw\\|tlpp\\|prx\\|apw\\|aph\\|apl\\|ch\\)\\)(\\([0-9]+\\))" 1 2 nil 2)
    (advpl-colon "\\([^ \t\n]+\\.\\(?:prw\\|tlpp\\|prx\\|apw\\|aph\\|apl\\|ch\\)\\):\\([0-9]+\\):\\([0-9]+\\)" 1 2 3 2)))

(defun advpl-compile--display (text &optional compilation)
  (let ((buffer (generate-new-buffer (if compilation "*ADVPL compilation*" "*ADVPL dry run*"))))
    (with-current-buffer buffer
      (when compilation
        (compilation-mode)
        (setq-local compilation-error-regexp-alist-alist
                    (append advpl-compile--error-regexps compilation-error-regexp-alist-alist))
        (setq-local compilation-error-regexp-alist '(advpl-paren advpl-colon)))
      (let ((inhibit-read-only t)) (insert text)))
    (display-buffer buffer)
    buffer))

(defun advpl-compile-files (files &optional root dry-run)
  "Compile FILES in ROOT with advpls, or preview masked INI when DRY-RUN.
Return the compilation buffer.  Never send credentials in process argv."
  (when (process-live-p advpl-compile--process)
    (user-error "An AdvPL compilation is already running; cancel it first"))
  (let* ((initial-root (or root (advpl-compile--root)))
         (config (advpl-compile--config initial-root))
         (base (alist-get 'root config))
         (sources (advpl-compile--files
                   (mapcar (lambda (file) (expand-file-name file base)) files))))
    (unless sources (user-error "No non-empty AdvPL/TLPP source files to compile"))
    (let ((ini (advpl-compile--ini config sources)))
      (setq advpl-compile--last (cons sources initial-root))
      (if dry-run
          (advpl-compile--display (advpl-compile--redact ini config))
        (let* ((cmd (advpl-compile--command))
               (path (advpl-compile--write-ini config ini))
               (buffer (advpl-compile--display (format "ADVPL: compiling %d file(s)\n\n"
                                                       (length sources)) t))
               (stdout "") (stderr "") (stderr-pipe nil))
          (condition-case err
              (let* ((default-directory (file-name-as-directory base))
                     (process (progn
                                (setq stderr-pipe
                                      (make-pipe-process
                                       :name "advpl-cli-stderr" :noquery t :buffer nil
                                       :filter (lambda (_process data)
                                                 (setq stderr (concat stderr data)))))
                                (make-process
                               :name "advpl-cli" :noquery t :buffer nil
                               :command (append cmd (list "cli" path))
                               :stderr stderr-pipe
                               :filter (lambda (_process data) (setq stdout (concat stdout data)))
                               :sentinel
                               (lambda (proc _event)
                                 (when (memq (process-status proc) '(exit signal))
                                   (when (file-exists-p path) (delete-file path))
                                   (setq advpl-compile--process nil)
                                   (when (process-live-p stderr-pipe)
                                     (accept-process-output stderr-pipe 0.01)
                                     (delete-process stderr-pipe))
                                   (let* ((raw (concat stdout "\n" stderr))
                                          (safe (advpl-compile--redact raw config))
                                          (success (and (= 0 (process-exit-status proc))
                                                        (string-match-p "All files compiled successfully" safe)
                                                        (string-match-p "Recompile finished" safe)
                                                        (not (string-match-p
                                                              "rollback changes\\|\\[ERROR\\]" safe)))))
                                     (when (buffer-live-p buffer)
                                       (with-current-buffer buffer
                                         (let ((inhibit-read-only t))
                                           (goto-char (point-max))
                                           (insert safe "\nCompilation "
                                                   (if success "finished" "failed")
                                                   "\n")))
                                       (setq advpl-compile--log-buffer buffer))
                                     (message "ADVPL compilation %s" (if success "finished" "failed")))))))))
                (setq advpl-compile--process process))
            (error
             (when (process-live-p stderr-pipe) (delete-process stderr-pipe))
             (when (file-exists-p path) (delete-file path))
             (when (buffer-live-p buffer) (kill-buffer buffer))
             (signal (car err) (cdr err))))
          buffer)))))

(defun advpl-compile-file (&optional dry-run)
  "Compile current source.  With prefix argument DRY-RUN, preview only."
  (interactive "P")
  (unless (and buffer-file-name (advpl-compile--source-p buffer-file-name))
    (user-error "Current buffer is not an AdvPL/TLPP source"))
  (when (and (not dry-run) (buffer-modified-p))
    (user-error "Save the source before sending it to the AppServer"))
  (advpl-compile-files (list buffer-file-name) (advpl-compile--root) dry-run))

(defun advpl-compile-project (&optional dry-run)
  "Compile project source roots; prefix argument previews only."
  (interactive "P")
  (let* ((root (advpl-compile--root))
         (config (advpl-compile--config root)))
    (advpl-compile-files (advpl-compile--project-files config) root dry-run)))

(defun advpl-compile-changed (&optional dry-run)
  "Compile changed, staged and untracked Git sources; prefix previews only."
  (interactive "P")
  (let* ((root (advpl-compile--root))
         (base (alist-get 'root (advpl-compile--config root))))
    (advpl-compile-files (advpl-compile--changed-files base) root dry-run)))

(defun advpl-compile-repeat (&optional dry-run)
  "Repeat last compile; prefix argument previews only."
  (interactive "P")
  (unless advpl-compile--last (user-error "No previous AdvPL compile"))
  (advpl-compile-files (car advpl-compile--last) (cdr advpl-compile--last) dry-run))

(defun advpl-compile-cancel ()
  "Cancel a running compile and remove its credential-bearing INI."
  (interactive)
  (unless (process-live-p advpl-compile--process) (user-error "No running AdvPL compilation"))
  (delete-process advpl-compile--process))

(defun advpl-compile-log ()
  "Open the last sanitized compilation output."
  (interactive)
  (unless (buffer-live-p advpl-compile--log-buffer) (user-error "No AdvPL compile log"))
  (pop-to-buffer advpl-compile--log-buffer))

(defun advpl-compile-status ()
  "Show connection settings and missing fields without secrets."
  (interactive)
  (let* ((config (advpl-compile--config (advpl-compile--root)))
         (fields '(server port environment user password))
         (missing (cl-remove-if (lambda (field) (alist-get field config)) fields)))
    (advpl-compile--display
     (format "Root: %s\nServer: %s\nPort: %s\nEnvironment: %s\nUser: %s\nPassword: %s\nIncludes: %s\nMissing: %s\n"
             (alist-get 'root config) (or (alist-get 'server config) "<missing>")
             (or (alist-get 'port config) "<missing>")
             (or (alist-get 'environment config) "<missing>")
             (if (alist-get 'user config) "<set>" "<missing>")
             (if (alist-get 'password config) "<set>" "<missing>")
             (mapconcat #'identity (alist-get 'includes config) "; ")
             (mapconcat #'symbol-name missing ", ")))))

(defun advpl-compile-use-profile (name)
  "Select a Neovim-compatible profile NAME for this Emacs session."
  (interactive "sAdvPL profile name (empty for project/default): ")
  (setq advpl-compile-profile (unless (string-empty-p name) name))
  (message "AdvPL profile: %s" (or advpl-compile-profile "project/default")))

(defvar advpl-compile-mode-map
  (let ((map (make-sparse-keymap)) (prefix (make-sparse-keymap)))
    (define-key map (kbd "C-c a") prefix)
    (dolist (binding '(("f" . advpl-compile-file) ("p" . advpl-compile-project)
                       ("g" . advpl-compile-changed) ("r" . advpl-compile-repeat)
                       ("x" . advpl-compile-cancel) ("l" . advpl-compile-log)
                       ("s" . advpl-compile-status) ("u" . advpl-compile-use-profile)))
      (define-key prefix (kbd (car binding)) (cdr binding)))
    map)
  "AdvPL compile commands under C-c a in `advpl-compile-mode'.")

;;;###autoload
(define-minor-mode advpl-compile-mode
  "Local compilation bindings for ADVPL/TLPP buffers."
  :lighter " Build" :keymap advpl-compile-mode-map)

(provide 'advpl-compile)
;;; advpl-compile.el ends here
