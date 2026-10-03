;;; check-aot-structure.el --- Reject misplaced callback definitions -*- lexical-binding: t; -*-
(require 'cl-lib)
(let ((source (car (last command-line-args-left)))
      (focused (getenv "NATIVE_IME_CHECK_FUNCTION")))
  (condition-case err
      (with-temp-buffer
        (emacs-lisp-mode)
        (insert-file-contents source)
        (check-parens)
        (goto-char (point-min))
        (let* ((program (read (current-buffer)))
               (violations nil)
               (definitions (cl-remove-if-not
                             (lambda (form) (eq (car-safe form) 'defun))
                             (cdr program))))
          (unless (eq (car-safe program) 'seq) (error "Expected one outer seq"))
          (unless (equal (mapcar #'cadr definitions)
                         '(print-label fail-engine json-member-object json-member-string
                           json-member-array render-candidates render-json render-response
                           queue-request dispatch-key enqueue-key drain-keys
                           on_key on_close on_poll main))
            (error "Unexpected direct function topology: %s"
                   (mapcar #'cadr definitions)))
          (when (and focused (not (member focused (mapcar
                                                   (lambda (form) (symbol-name (cadr form)))
                                                   definitions))))
            (error "Unknown focused callback: %s" focused))
          (dolist (definition (if focused
                                 (cl-remove-if-not
                                  (lambda (form) (equal (symbol-name (cadr form)) focused))
                                  definitions)
                               definitions))
            (unless (= (length definition) 4)
              (error "Callback %s must have one body expression" (cadr definition)))
            (cl-labels ((inspect (form)
                          (when (stringp form)
                            (error "Inline boxed string in %s; use data-blob/data-addr"
                                   (cadr definition)))
                          (when (consp form)
                            (when (and (memq (car form) '(let while when))
                                       (/= (length form) 3))
                              (push (format "Raw %s needs one body in %s (arity %d)"
                                            (car form) (cadr definition) (length form)) violations))
                            (when (and (eq (car form) 'if)
                                       (not (memq (length form) '(3 4))))
                              (push (format "Invalid raw if in %s (arity %d)"
                                            (cadr definition) (length form)) violations))
                            (when (and (memq (car form) '(ptr-read-u8 ptr-read-u64))
                                       (/= (length form) 3))
                              (push (format "Invalid pointer read in %s" (cadr definition)) violations))
                            (when (and (memq (car form) '(ptr-write-u8 ptr-write-u64))
                                       (/= (length form) 4))
                              (push (format "Invalid pointer write in %s" (cadr definition)) violations))
                            (when (eq (car form) 'defun)
                              (error "Nested callback in %s" (cadr definition)))
                            (mapc #'inspect form))))
              (inspect (nth 3 definition))))
          (when violations (error "%s" (mapconcat #'identity (nreverse violations) "; ")))
          (forward-comment (point-max))
          (unless (eobp) (error "Unexpected extra source form"))
          (princ (format "STRUCTURE-PASS scope=%s: %s\n"
                         (or focused "all") (mapcar #'cadr definitions)))))
    (error (princ (format "STRUCTURE-ERROR: %s\n" (error-message-string err)))
           (kill-emacs 1))))
