;;; nelisp-ime-protocol.el --- Versioned JSON-RPC protocol for NeLisp IME -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A line-delimited JSON-RPC boundary shared by native platform adapters.

;;; Code:

(require 'nelisp-json)
(require 'nelisp-ime)

(defconst nelisp-ime-protocol-version 1)

(defun nelisp-ime-protocol--object (&rest pairs)
  "Build a JSON object from alternating PAIRS."
  (let ((object (make-hash-table :test 'equal)))
    (while pairs
      (puthash (car pairs) (cadr pairs) object)
      (setq pairs (cddr pairs)))
    object))

(defun nelisp-ime-protocol--input-style (value)
  "Validate and translate JSON input style VALUE."
  (cond ((or (equal value "kana") (eq value 'kana)) 'kana)
        ((or (equal value "romaji") (eq value 'romaji)) 'romaji)
        (t (error "nelisp-ime: unsupported input style %S" value))))

(defun nelisp-ime-protocol--operation (value)
  "Validate and translate JSON operation VALUE."
  (let ((entry (assoc value '(("key" . :key) ("insert" . :insert)
                              ("backspace" . :backspace)
                              ("select-segment" . :select-segment)
                              ("select-candidate" . :select-candidate)
                              ("commit" . :commit) ("cancel" . :cancel)))))
    (or (cdr entry) (error "nelisp-ime: unsupported operation %S" value))))

(defun nelisp-ime-protocol--event (object)
  "Translate JSON event OBJECT into the core event plist."
  (list :op (nelisp-ime-protocol--operation (gethash "op" object))
        :text (gethash "text" object)
        :key (gethash "key" object)
        :code (gethash "code" object)
        :shift (eq (gethash "shift" object) t)
        :index (gethash "index" object)))

(defun nelisp-ime-protocol-dispatch (method params)
  "Dispatch protocol METHOD with JSON object PARAMS."
  (cond
   ((equal method "ime/initialize")
    (let ((requested (gethash "protocolVersion" params)))
      (unless (= requested nelisp-ime-protocol-version)
        (error "nelisp-ime: unsupported protocol version %S" requested))
      (list :protocolVersion nelisp-ime-protocol-version
            :engine "nelisp-ime"
            :capabilities ["kana" "romaji" "live-conversion" "learning"
                           "multi-session"])))
   ((equal method "ime/health") (list :ok t))
   ((equal method "ime/dictionary.load")
    (list :entries
          (nelisp-ime-dictionary-load-skk
           (gethash "file" params)
           (and (equal (gethash "coding" params) "utf-8") 'utf-8))))
   ((equal method "ime/session.open")
    (nelisp-ime-session-open
     (gethash "sessionId" params)
     (list :input-style
           (nelisp-ime-protocol--input-style (gethash "inputStyle" params))
           :context (gethash "context" params))))
   ((equal method "ime/session.close")
    (list :closed (nelisp-ime-session-close (gethash "sessionId" params))))
   ((equal method "ime/session.feed")
    (nelisp-ime-feed (gethash "sessionId" params)
                     (nelisp-ime-protocol--event (gethash "event" params))))
   ((equal method "ime/learning.load")
    (list :rows (nelisp-ime-learning-load (gethash "file" params))))
   ((equal method "ime/learning.save")
    (list :file (nelisp-ime-learning-save (gethash "file" params))))
   ((equal method "ime/learning.export")
    (list :rows (vconcat (nelisp-ime-learning-export))))
   ((equal method "ime/learning.import")
    (list :rows (nelisp-ime-learning-import (gethash "rows" params))))
   (t (error "nelisp-ime: unknown method %S" method))))

(defun nelisp-ime-protocol--response (id result)
  "Encode successful RESULT for request ID."
  (nelisp-json-encode
   (nelisp-ime-protocol--object
    "jsonrpc" "2.0" "id" id "result" result)))

(defun nelisp-ime-protocol--error (id error-data)
  "Encode ERROR-DATA for request ID."
  (nelisp-json-encode
   (nelisp-ime-protocol--object
    "jsonrpc" "2.0" "id" id
    "error" (nelisp-ime-protocol--object
             "code" -32603 "message" (format "%S" error-data)))))

(defun nelisp-ime-protocol-handle-json (line)
  "Handle one line-delimited JSON-RPC request LINE and return JSON."
  (let (id)
    (condition-case err
      (let* ((request (nelisp-json-parse-string line))
             (_ (setq id (gethash "id" request)))
             (params (or (gethash "params" request)
                         (make-hash-table :test 'equal))))
        (nelisp-ime-protocol--response
         id (nelisp-ime-protocol-dispatch (gethash "method" request) params)))
      (error (nelisp-ime-protocol--error id err)))))

(provide 'nelisp-ime-protocol)
;;; nelisp-ime-protocol.el ends here
