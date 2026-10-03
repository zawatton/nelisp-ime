;;; build-probe.el --- Compile the native GTK probe to ELF -*- lexical-binding: t; -*-

(defun nelisp-probe--source-overlay (source-root destination)
  "Symlink only .el files from SOURCE-ROOT into DESTINATION."
  (make-directory destination t)
  (dolist (source (directory-files-recursively source-root "\\.el\\'"))
    (let* ((relative (file-relative-name source source-root))
           (target (expand-file-name relative destination)))
      (make-directory (file-name-directory target) t)
      (make-symbolic-link source target t))))

(let* ((here (file-name-directory (or load-file-name buffer-file-name)))
       (nelisp-root (or (getenv "NELISP_ROOT")
                        (expand-file-name "../../../../nelisp" here)))
       (_separator (when (equal (car command-line-args-left) "--")
                     (setq command-line-args-left (cdr command-line-args-left))))
       (source (car command-line-args-left))
       (out-dir (or (getenv "NELISP_PROBE_OUT_DIR")
                    (expand-file-name "build" here)))
       (output (or (getenv "NELISP_PROBE_OBJECT")
                   (expand-file-name "native-probe.o" out-dir)))
       (overlay (make-temp-file "nelisp-probe-elisp-" t))
       (failed nil))
  (unless source (error "Usage: emacs -Q --batch -l build-probe.el -- native-probe.el"))
  (unwind-protect
      (condition-case err
          (progn
            (nelisp-probe--source-overlay (expand-file-name "lisp" nelisp-root)
                                          (expand-file-name "lisp" overlay))
            (nelisp-probe--source-overlay (expand-file-name "src" nelisp-root)
                                          (expand-file-name "src" overlay))
            ;; Keep Emacs' normal system load suffixes; only repo directories
            ;; are overlaid with source-only symlinks.
            (add-to-list 'load-path (expand-file-name "lisp" overlay))
            (add-to-list 'load-path (expand-file-name "src" overlay))
            (require 'nelisp-aot-compiler)
            (let ((source-file (expand-file-name source)))
              (with-temp-buffer
                (insert-file-contents source-file)
                (goto-char (point-min))
                (let ((program (read (current-buffer))))
                  (skip-chars-forward " \t\r\n")
                  (unless (eobp) (error "Expected exactly one AOT program form"))
                  (make-directory (file-name-directory output) t)
                  (nelisp-aot-compile-to-object program output :arch 'x86_64 :format 'elf)))
            (princ (format "ELF object written: %s\n" output))))
        (error
         (let ((detail (error-message-string err)))
           (princ (format "COMPILE-ERROR: %s\n"
                          (substring detail 0 (min 600 (length detail))))))
         (setq failed t)))
    (delete-directory overlay t))
  (when failed (kill-emacs 1)))

;;; build-probe.el ends here
