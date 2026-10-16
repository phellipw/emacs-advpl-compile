;;; advpl-compile-test.el --- Tests for AdvPL compilation -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'advpl-compile)

(defmacro advpl-test-with-project (&rest body)
  "Run BODY with an isolated project and configuration home."
  (declare (indent 0))
  `(let* ((fixture (make-temp-file (expand-file-name "advpl-ert-" default-directory) t))
          (default-directory (file-name-as-directory fixture))
          (process-environment (copy-sequence process-environment))
          (advpl-compile-profile nil)
          (advpl-compile-temp-directory (file-name-as-directory fixture))
          (advpl-compile--last nil)
          (advpl-compile--process nil))
     (unwind-protect
         (progn
           (setenv "XDG_CONFIG_HOME" (expand-file-name "config" fixture))
           (setenv "XDG_STATE_HOME" (expand-file-name "state" fixture))
           (setenv "ADVPL_PROFILE" nil)
           (setenv "ADVPL_USER" nil)
           (setenv "ADVPL_PASSWORD" nil)
           (setenv "ADVPL_USE_PROJECT_OVERRIDES" nil)
           ,@body)
       (when (process-live-p advpl-compile--process)
         (delete-process advpl-compile--process))
       (delete-directory fixture t))))

(defun advpl-test-file (path text)
  "Write TEXT to PATH in the current test project."
  (let ((file (expand-file-name path)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))
    file))

(ert-deftest advpl-test-config-precedence-and-profile ()
  (advpl-test-with-project
    (advpl-test-file ".advpl-build.json"
                     "{\"profile\":\"dev\",\"server\":\"project\",\"port\":123,\"environment\":\"DEV\",\"includes\":[\"inc\"]}")
    (advpl-test-file ".advpl-build.local.json" "{\"environment\":\"LOCAL\"}")
    (advpl-test-file (expand-file-name "advpl/dev/build.json" (getenv "XDG_CONFIG_HOME"))
                     "{\"server\":\"profile\",\"includes\":[\"~/profile-inc\"]}")
    (let ((config (advpl-compile--config default-directory)))
      (should (equal (alist-get 'server config) "profile"))
      (should (equal (alist-get 'environment config) "LOCAL"))
      (should (equal (alist-get 'includes config) (list (expand-file-name "~/profile-inc")))))
    (advpl-test-file ".advpl-build.local.json" "{\"useProjectOverrides\":true,\"server\":\"local-project\"}")
    (should (equal (alist-get 'server (advpl-compile--config default-directory)) "local-project"))
    (setenv "ADVPL_SERVER" "env-server")
    (should (equal (alist-get 'server (advpl-compile--config default-directory)) "env-server"))))

(ert-deftest advpl-test-persisted-nvim-profile ()
  (advpl-test-with-project
    (advpl-test-file (expand-file-name "nvim/advpl/profile.json" (getenv "XDG_STATE_HOME"))
                     "{\"profile\":\"staging\"}")
    (advpl-test-file (expand-file-name "advpl/staging/build.json" (getenv "XDG_CONFIG_HOME"))
                     "{\"server\":\"stage-host\"}")
    (should (equal (alist-get 'server (advpl-compile--config default-directory)) "stage-host"))))

(ert-deftest advpl-test-file-discovery-and-empty-files ()
  (advpl-test-with-project
    (advpl-test-file ".advpl-build.json" "{\"sourceRoots\":[\"src\"]}")
    (let ((one (advpl-test-file "src/nested/a.prw" "User Function X\nReturn")))
      (advpl-test-file "src/empty.tlpp" "")
      (advpl-test-file "src/skip.txt" "not source")
      (should (equal (advpl-compile--project-files (advpl-compile--config default-directory))
                     (list one))))))

(ert-deftest advpl-test-ini-security-and-cp1252 ()
  (advpl-test-with-project
    (let* ((file (advpl-test-file "src/acento.prw" "Return"))
           (config `((server . "host") (port . 13122) (environment . "DEV")
                     (user . "user") (password . "not-a-real-password")
                     (secure . 0) (build . "AUTO") (recompile . t)
                     (includes . ("C:/cabeçalho")) (script-encoding . "cp1252")))
           (ini (advpl-compile--ini config (list file))))
      (should (string-prefix-p "showConsoleOutput=true\n\n[authentication]\naction=authentication\nserver=host" ini))
      (should (< (string-match "\\[compile\\]" ini) (string-match (regexp-quote (concat "program=" file)) ini)))
      (should (string-match-p "build=AUTO" ini))
      (should (equal (decode-coding-string (encode-coding-string ini 'windows-1252 t)
                                          'windows-1252 t) ini))
      (should-not (string-match-p "not-a-real-password" (advpl-compile--redact ini config)))
      (should-error (advpl-compile--ini (cons '(user . "bad\nserver=evil") config) (list file)))
      (should-error (advpl-compile--ini config (list "bad,other.prw")))
      (should-error (advpl-compile--encode "not encodable 🪐" "cp1252"))
      (should-error (advpl-compile--write-ini config "not encodable 🪐"))
      (should-not (directory-files default-directory nil "advpl-compile-.*\\.ini\\'")))))

(ert-deftest advpl-test-dry-run-masks-password-and-writes-no-ini ()
  (advpl-test-with-project
    (let ((file (advpl-test-file "a.prw" "Return")))
      (advpl-test-file ".advpl-build.json" "{\"server\":\"host\",\"port\":13122,\"environment\":\"DEV\"}")
      (setenv "ADVPL_USER" "tester")
      (setenv "ADVPL_PASSWORD" "top-secret-test-password")
      (let ((buffer (advpl-compile-files (list file) default-directory t)))
        (unwind-protect
            (with-current-buffer buffer
              (should-not (string-match-p "top-secret-test-password" (buffer-string)))
              (should (string-match-p "psw=\\*\\*\\*" (buffer-string))))
          (kill-buffer buffer)))
      (should-not (directory-files default-directory nil "\\.ini\\'")))))

(ert-deftest advpl-test-cli-success-cleans-ini-and-sanitizes-output ()
  (advpl-test-with-project
    (let* ((file (advpl-test-file "a.prw" "Return"))
           (script (advpl-test-file "fake-advpls" "#!/bin/sh\ntest \"$1\" = cli || exit 2\nprintf '[SUCCESS] Source %s(5) compiled successfully\\n' \"$3\"\nprintf 'psw=top-secret-test-password\\n'\nprintf '[INFO] All files compiled successfully.\\n[INFO] Recompile finished.\\n'\n"))
           (advpl-compile-command (list script))
           (advpl-compile-temp-directory default-directory))
      (set-file-modes script #o700)
      (advpl-test-file ".advpl-build.json" "{\"server\":\"host\",\"port\":13122,\"environment\":\"DEV\"}")
      (setenv "ADVPL_USER" "tester")
      (setenv "ADVPL_PASSWORD" "top-secret-test-password")
      (let* ((original (symbol-function 'advpl-compile--write-ini))
             (buffer (cl-letf (((symbol-function 'advpl-compile--write-ini)
                                (lambda (config ini)
                                  (let ((path (funcall original config ini)))
                                    (should (= (file-modes path) #o600))
                                    path))))
                       (advpl-compile-files (list file) default-directory nil))))
        (should-not (string-match-p "top-secret-test-password"
                                    (mapconcat #'identity (process-command advpl-compile--process) " ")))
        (unwind-protect
            (progn
              (while (process-live-p advpl-compile--process)
                (accept-process-output advpl-compile--process 0.1))
              (accept-process-output nil 0.1)
              (with-current-buffer buffer
                (should (string-match-p "All files compiled successfully" (buffer-string)))
                (should-not (string-match-p "top-secret-test-password" (buffer-string)))
                (should (string-match-p "Compilation finished" (buffer-string)))))
          (kill-buffer buffer)))
      (should-not (directory-files default-directory nil "\\.ini\\'")))))

(ert-deftest advpl-test-project-root-and-repeat ()
  (advpl-test-with-project
    (let ((file (advpl-test-file "alternate/hello.prw" "Return")))
      (advpl-test-file ".advpl-build.json"
                       "{\"server\":\"project-host\",\"port\":13122,\"environment\":\"DEV\",\"projectRoot\":\"alternate\"}")
      (setenv "ADVPL_USER" "tester")
      (setenv "ADVPL_PASSWORD" "repeat-test-secret")
      (let ((first (advpl-compile-files (list file) default-directory t)))
        (unwind-protect
            (progn
              (should (equal (cdr advpl-compile--last) default-directory))
              (with-current-buffer (advpl-compile-repeat t)
                (unwind-protect
                    (should (string-match-p "server=project-host" (buffer-string)))
                  (kill-buffer (current-buffer)))))
          (kill-buffer first))))))

(ert-deftest advpl-test-status-does-not-disclose-local-credentials ()
  (advpl-test-with-project
    (advpl-test-file ".advpl-build.json" "{\"server\":\"host\",\"port\":13122,\"environment\":\"DEV\"}")
    (advpl-test-file ".advpl-build.local.json" "{\"user\":\"tester\",\"password\":\"synthetic-status-test-secret\"}")
    (let ((buffer (advpl-compile-status)))
      (unwind-protect
          (with-current-buffer buffer
            (should-not (string-match-p "synthetic-status-test-secret" (buffer-string)))
            (should (string-match-p "Password: <set>" (buffer-string))))
        (kill-buffer buffer)))))

(ert-deftest advpl-test-git-changed-sources ()
  (advpl-test-with-project
    (let ((default-directory (expand-file-name default-directory)))
      (should (= 0 (process-file "git" nil nil nil "init" "-q" default-directory)))
      (let ((staged (advpl-test-file "staged.prw" "Return"))
            (untracked (advpl-test-file "untracked.tlpp" "Return")))
        (advpl-test-file "ignore.txt" "other")
        (should (= 0 (process-file "git" nil nil nil "add" "staged.prw")))
        (should (equal (advpl-compile--changed-files default-directory)
                       (list staged untracked)))))))

(ert-deftest advpl-test-compilation-errors-are-navigable ()
  (advpl-test-with-project
    (let* ((file (advpl-test-file "invalid.prw" "first\nsecond\nthird"))
           (buffer (advpl-compile--display
                    (format "[ERROR] %s(3) C2001 syntax error\n" file) t)))
      (unwind-protect
          (with-current-buffer buffer
            (goto-char (point-min))
            (let ((diagnostic (compilation-next-error 1)))
              (should diagnostic)
              (should (= 3 (nth 1 (compilation--message->loc diagnostic))))))
        (kill-buffer buffer)))))

(ert-deftest advpl-test-file-scope-rejects-unsaved-buffer ()
  (advpl-test-with-project
    (let ((file (advpl-test-file "edit.prw" "Return")))
      (with-current-buffer (find-file-noselect file)
        (unwind-protect
            (progn
              (insert "Changed")
              (should-error (advpl-compile-file nil) :type 'user-error)
              (should (buffer-modified-p)))
          (set-buffer-modified-p nil)
          (kill-buffer (current-buffer)))))))

(ert-deftest advpl-test-cancel-removes-private-ini ()
  (advpl-test-with-project
    (let* ((file (advpl-test-file "cancel.prw" "Return"))
           (script (advpl-test-file "fake-advpls" "#!/bin/sh\nread -r ignored\n"))
           (advpl-compile-command (list script))
           (advpl-compile-temp-directory default-directory))
      (set-file-modes script #o700)
      (advpl-test-file ".advpl-build.json" "{\"server\":\"host\",\"port\":13122,\"environment\":\"DEV\"}")
      (setenv "ADVPL_USER" "tester")
      (setenv "ADVPL_PASSWORD" "cancel-test-password")
      (let ((buffer (advpl-compile-files (list file) default-directory nil)))
        (unwind-protect
            (progn
              (should (process-live-p advpl-compile--process))
              (advpl-compile-cancel)
              (accept-process-output nil 0.1)
              (should-not (directory-files default-directory nil "advpl-compile-.*\\.ini\\'")))
          (kill-buffer buffer))))))

(ert-deftest advpl-test-exit-zero-without-commit-marker-is-failure ()
  (advpl-test-with-project
    (let* ((file (advpl-test-file "a.prw" "Return"))
           (script (advpl-test-file "fake-advpls" "#!/bin/sh\necho 'Something happened'\n"))
           (advpl-compile-command (list script))
           (advpl-compile-temp-directory default-directory))
      (set-file-modes script #o700)
      (advpl-test-file ".advpl-build.json" "{\"server\":\"host\",\"port\":13122,\"environment\":\"DEV\"}")
      (setenv "ADVPL_USER" "tester")
      (setenv "ADVPL_PASSWORD" "test-secret")
      (let ((buffer (advpl-compile-files (list file) default-directory nil)))
        (unwind-protect
            (progn
              (while (process-live-p advpl-compile--process)
                (accept-process-output advpl-compile--process 0.1))
              (accept-process-output nil 0.1)
              (with-current-buffer buffer
                (should (string-match-p "Compilation failed" (buffer-string)))))
          (kill-buffer buffer)))
      (should-not (directory-files default-directory nil "\\.ini\\'")))))

(provide 'advpl-compile-test)
;;; advpl-compile-test.el ends here
