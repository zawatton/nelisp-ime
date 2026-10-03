;;; engine-entry.el --- NeLisp IME subprocess entry point -*- lexical-binding: t; -*-

(let* ((root (getenv "NELISP_IME_ROOT"))
       (files '("packages/nelisp-json/src/nelisp-json.el"
                "packages/nelisp-ime/src/nelisp-ime-input.el"
                "packages/nelisp-ime/src/nelisp-ime.el"
                "packages/nelisp-ime-lattice/src/nelisp-ime-lattice.el"
                "packages/nelisp-ime-lattice/data/nelisp-ime-dictionary-data.el"
                "packages/nelisp-ime/src/nelisp-ime-protocol.el")))
  (unless (and root (file-directory-p root))
    (error "NELISP_IME_ROOT must name the NeLisp checkout"))
  (dolist (file files) (load (expand-file-name file root) nil t)))

(defvar native-ime-request-id 0)

(defun native-ime-request (operation key &optional index)
  "Send OPERATION and ASCII KEY through the real versioned IME protocol."
  (unless (member operation '("key" "backspace" "commit" "cancel"
                              "select-candidate"))
    (error "Unsupported GTK IME operation: %s" operation))
  (let* ((id (setq native-ime-request-id (1+ native-ime-request-id)))
         (event (if (equal operation "key")
                    (format "\"op\":\"key\",\"key\":%s"
                            (nelisp-json-encode-string key))
                  (if (equal operation "backspace")
                      "\"op\":\"backspace\""
                  (if (equal operation "select-candidate")
                      (format "\"op\":\"select-candidate\",\"index\":%d"
                              (max 0 (or index 0)))
                    (format "\"op\":%s"
                            (nelisp-json-encode-string operation))))))
         (params (concat "\"sessionId\":\"gtk\",\"event\":{" event "}"))
         (request (format "{\"jsonrpc\":\"2.0\",\"id\":%d,\"method\":\"ime/session.feed\",\"params\":{%s}}"
                          id params)))
    (princ (concat (nelisp-ime-protocol-handle-json request) "\n"))))

(nelisp-ime-protocol-handle-json
 "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ime/initialize\",\"params\":{\"protocolVersion\":1}}")
(nelisp-ime-protocol-handle-json
 "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ime/session.open\",\"params\":{\"sessionId\":\"gtk\",\"inputStyle\":\"romaji\"}}")
(princ "READY\n")
;;; engine-entry.el ends here
