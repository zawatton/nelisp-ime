;;; nelisp-ime.el --- Portable NeLisp input method framework core  -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; OS-independent input method sessions.  Platform adapters normalize native
;; key events before calling this package and render the returned snapshot with
;; InputMethodKit, Fcitx/IBus, or TSF.
;;
;; This file is the engine-agnostic framework: composition sessions, reading
;; accumulation (kana and romaji), candidate/segment selection, frequency
;; learning, and the engine registry.  Conversion itself is pluggable — an
;; engine registers a `:convert' function under a name (see
;; `nelisp-ime-engine-register'), sessions select one with the `:engine'
;; option, and `nelisp-ime-default-engine' names the fallback.  The bundled
;; minimum-cost lattice engine lives in `nelisp-ime-lattice' and registers
;; itself as `lattice'.

;;; Code:

(require 'cl-lib)
(require 'nelisp-ime-input)

(defgroup nelisp-ime nil
  "Portable input method framework core."
  :group 'nelisp
  :prefix "nelisp-ime-")

(defvar nelisp-ime-sessions (make-hash-table :test 'equal)
  "Active input sessions keyed by platform-supplied string identifiers.")

(defvar nelisp-ime-dictionary nil
  "Alist mapping readings to ordered conversion candidates.

A candidate may be a surface string or a plist containing :surface and
:cost.  Lower costs win.  String candidates receive costs from their order.")

(defvar nelisp-ime-learning (make-hash-table :test 'equal)
  "Selection frequencies keyed by a reading and surface pair.")

(defvar nelisp-ime-learning-weight 100
  "Cost reduction applied for each learned candidate selection.")

(defvar nelisp-ime-converter-function nil
  "Function called with READING and CONTEXT to produce a conversion plist.

When non-nil this overrides `nelisp-ime-default-engine' for sessions that
did not select an engine explicitly.  Prefer registering an engine with
`nelisp-ime-engine-register'; this variable remains as the low-level hook.")

;;; Engine registry

(defvar nelisp-ime-engines (make-hash-table :test 'eq)
  "Registered conversion engines keyed by symbol name.")

(defvar nelisp-ime-default-engine 'lattice
  "Engine used by sessions that do not select one explicitly.

The name only takes effect once an engine registers under it, so the
framework loads without any engine and adapters may swap the default before
or after engines load.")

;;;###autoload
(defun nelisp-ime-engine-register (name &rest hooks)
  "Register conversion engine NAME with HOOKS and return NAME.

NAME is a symbol.  HOOKS is a plist:
  :convert  function of READING and CONTEXT returning a plist with
            :preedit, :candidates, and :segments — the same contract as
            `nelisp-ime-converter-function'.
  :feed     function of SESSION-ID, SESSION, and EVENT returning a public
            snapshot.  A modal engine (SKK-style) that owns key handling
            supplies this to intercept every event before the framework's
            default composition pipeline; such an engine may omit :convert.
  :learn    (optional) function of SEGMENTS called on commit in place of
            the framework frequency learning.

At least one of :convert or :feed is required.  Registering NAME again
replaces the previous definition."
  (unless (symbolp name)
    (error "nelisp-ime: engine name must be a symbol"))
  (unless (or (functionp (plist-get hooks :convert))
              (functionp (plist-get hooks :feed)))
    (error "nelisp-ime: engine %s requires :convert or :feed" name))
  (puthash name (append (list :name name) hooks) nelisp-ime-engines)
  name)

(defun nelisp-ime-engine-get (name)
  "Return the engine plist registered under symbol NAME, or nil."
  (and (symbolp name) name (gethash name nelisp-ime-engines)))

(defun nelisp-ime-engine-names ()
  "Return registered engine names sorted by `string<'."
  (let (names)
    (maphash (lambda (name _engine) (push name names)) nelisp-ime-engines)
    (sort names (lambda (left right)
                  (string< (symbol-name left) (symbol-name right))))))

(defun nelisp-ime--session-engine (session)
  "Return the engine plist governing SESSION, or nil for the legacy hook.

Resolution order: the session's :engine name, then
`nelisp-ime-converter-function' (which returns nil here so the caller uses
the hook directly), then `nelisp-ime-default-engine'."
  (let ((name (plist-get session :engine)))
    (cond
     (name (or (nelisp-ime-engine-get name)
               (error "nelisp-ime: unknown engine %s" name)))
     (nelisp-ime-converter-function nil)
     (t (nelisp-ime-engine-get nelisp-ime-default-engine)))))

(defun nelisp-ime--convert (session reading context)
  "Convert READING with CONTEXT using the engine governing SESSION."
  (let ((engine (nelisp-ime--session-engine session)))
    (funcall (or (and engine (plist-get engine :convert))
                 nelisp-ime-converter-function
                 #'nelisp-ime-dictionary-convert)
             reading context)))

;;; Reference exact-match engine

(defun nelisp-ime-dictionary-convert (reading _context)
  "Convert READING using `nelisp-ime-dictionary'.

The first candidate is the live preedit.  An unknown reading remains kana.
This exact-reading converter is intentionally small; lattice or modal
engines replace it without changing the session or platform adapter APIs."
  (let ((candidates (cdr (assoc reading nelisp-ime-dictionary))))
    (list :preedit (or (car candidates) reading)
          :candidates (or candidates (and (> (length reading) 0)
                                          (list reading)))
          :segments (and (> (length reading) 0)
                         (list (list :from 0 :to (length reading)
                                     :reading reading
                                     :candidate (or (car candidates)
                                                    reading)))))))

(nelisp-ime-engine-register 'dictionary
                            :convert #'nelisp-ime-dictionary-convert)

;;; Shared candidate and learning helpers

(defun nelisp-ime--candidate-normalize (candidate rank)
  "Return a normalized candidate plist for CANDIDATE at RANK."
  (cond
   ((stringp candidate) (list :surface candidate :cost (+ 100 (* rank 10))))
   ((and (listp candidate) (stringp (plist-get candidate :surface)))
    (list :surface (plist-get candidate :surface)
          :cost (or (plist-get candidate :cost) (+ 100 (* rank 10)))))
   (t (error "nelisp-ime: invalid dictionary candidate %S" candidate))))

(defun nelisp-ime--learning-key (reading surface)
  "Return an unambiguous learning key for READING and SURFACE."
  (cons reading surface))

(defun nelisp-ime-learning-count (reading surface)
  "Return learned selection count for READING and SURFACE."
  (or (gethash (nelisp-ime--learning-key reading surface)
               nelisp-ime-learning)
      0))

(defun nelisp-ime--learn-segments (segments)
  "Increase selection frequencies represented by SEGMENTS."
  (dolist (segment segments)
    (let* ((reading (plist-get segment :reading))
           (surface (plist-get segment :candidate))
           (key (and reading surface
                     (nelisp-ime--learning-key reading surface))))
      (when key
        (puthash key (1+ (or (gethash key nelisp-ime-learning) 0))
                 nelisp-ime-learning)))))

(defun nelisp-ime-learning-export ()
  "Return deterministic readable learning rows."
  (let (rows)
    (maphash (lambda (key count)
               (push (list (car key) (cdr key) count) rows))
             nelisp-ime-learning)
    (sort rows
          (lambda (left right)
            (or (string< (car left) (car right))
                (and (equal (car left) (car right))
                     (string< (nth 1 left) (nth 1 right))))))))

(defun nelisp-ime-learning-import (rows)
  "Replace learning state with validated ROWS and return its row count."
  (when (vectorp rows) (setq rows (append rows nil)))
  (unless (listp rows) (error "nelisp-ime: invalid learning rows"))
  (let ((table (make-hash-table :test 'equal)))
    (dolist (row rows)
      (when (vectorp row) (setq row (append row nil)))
      (unless (and (listp row) (= (length row) 3)
                   (stringp (nth 0 row)) (stringp (nth 1 row))
                   (integerp (nth 2 row)) (>= (nth 2 row) 0))
        (error "nelisp-ime: invalid learning row %S" row))
      (puthash (nelisp-ime--learning-key (nth 0 row) (nth 1 row))
               (nth 2 row) table))
    (setq nelisp-ime-learning table)
    (hash-table-count table)))

;;;###autoload
(defun nelisp-ime-learning-save (file)
  "Atomically save learning state to FILE."
  (let ((temporary (concat file ".tmp")))
    (make-directory (file-name-directory (expand-file-name file)) t)
    (with-temp-file temporary
      (let ((print-length nil) (print-level nil))
        (prin1 (nelisp-ime-learning-export) (current-buffer))
        (insert "\n")))
    (rename-file temporary file t)
    file))

;;;###autoload
(defun nelisp-ime-learning-load (file)
  "Load validated learning state from FILE without evaluating code."
  (if (not (file-readable-p file))
      0
    (with-temp-buffer
      (insert-file-contents file)
      (let* ((parsed (read-from-string (buffer-string)))
             (rows (car parsed))
             (end (cdr parsed)))
        (unless (string-match-p "\\`[[:space:]]*\\'"
                                (substring (buffer-string) end))
          (error "nelisp-ime: trailing learning data"))
        (nelisp-ime-learning-import rows)))))

;;; Sessions

(defun nelisp-ime--check-session-id (session-id)
  "Require SESSION-ID to be a non-empty string."
  (unless (and (stringp session-id) (> (length session-id) 0))
    (error "nelisp-ime: session id must be a non-empty string")))

(defun nelisp-ime--session (session-id)
  "Return SESSION-ID state or signal an error when it is not open."
  (or (gethash session-id nelisp-ime-sessions)
      (error "nelisp-ime: unknown session %s" session-id)))

(defun nelisp-ime--segment-preedit (segments)
  "Concatenate selected candidates from SEGMENTS."
  (mapconcat (lambda (segment) (plist-get segment :candidate)) segments ""))

(defun nelisp-ime--reconvert (session)
  "Recompute live conversion fields in SESSION and return SESSION."
  (let* ((reading (plist-get session :reading))
         (context (plist-get session :context))
         (conversion (nelisp-ime--convert session reading context)))
    (setq session (plist-put session :preedit
                             (or (plist-get conversion :preedit) reading)))
    (setq session (plist-put session :candidates
                             (plist-get conversion :candidates)))
    (setq session (plist-put session :segments
                             (plist-get conversion :segments)))
    (setq session (plist-put session :active-segment 0))
    (plist-put session :candidate-index 0)))

(defun nelisp-ime--snapshot (session &optional commit)
  "Return the public representation of SESSION, optionally with COMMIT text."
  (list :consumed t
        :reading (plist-get session :reading)
        :preedit (concat (or (plist-get session :preedit) "")
                         (or (plist-get session :pending) ""))
        :segments
        (vconcat
         (mapcar (lambda (segment)
                   (let ((copy (copy-sequence segment)))
                     (plist-put copy :candidates
                                (vconcat (or (plist-get copy :candidates) nil)))))
                 (or (plist-get session :segments) nil)))
        :candidates (vconcat (or (plist-get session :candidates) nil))
        :candidate-index (plist-get session :candidate-index)
        :active-segment (plist-get session :active-segment)
        :pending (plist-get session :pending)
        :commit commit))

;;;###autoload
(defun nelisp-ime-session-open (session-id &optional options)
  "Open or replace SESSION-ID using platform-neutral OPTIONS.

OPTIONS may contain :input-style, :context, and :engine.  Input-style is
metadata for the platform adapter; physical key layout normalization stays
outside core.  :engine names a registered conversion engine for this
session; omitting it defers to `nelisp-ime-converter-function' and then
`nelisp-ime-default-engine'."
  (nelisp-ime--check-session-id session-id)
  (let ((engine (plist-get options :engine)))
    (when engine
      (unless (nelisp-ime-engine-get engine)
        (error "nelisp-ime: unknown engine %s" engine)))
    (let ((session (list :id session-id
                         :input-style (or (plist-get options :input-style)
                                          'kana)
                         :context (plist-get options :context)
                         :engine engine
                         :reading ""
                         :pending ""
                         :preedit ""
                         :segments nil
                         :candidates nil
                         :active-segment 0
                         :candidate-index 0)))
      (puthash session-id session nelisp-ime-sessions)
      (nelisp-ime--snapshot session))))

;;;###autoload
(defun nelisp-ime-session-close (session-id)
  "Close SESSION-ID and discard its uncommitted composition."
  (nelisp-ime--check-session-id session-id)
  (remhash session-id nelisp-ime-sessions))

(defun nelisp-ime--store (session-id session)
  "Store SESSION under SESSION-ID and return its public snapshot."
  (puthash session-id session nelisp-ime-sessions)
  (nelisp-ime--snapshot session))

(defun nelisp-ime--insert (session-id session text)
  "Append normalized TEXT to SESSION-ID and run live conversion."
  (unless (stringp text)
    (error "nelisp-ime: :insert requires string :text"))
  (setq session
        (plist-put session :reading
                   (concat (plist-get session :reading) text)))
  (nelisp-ime--store session-id (nelisp-ime--reconvert session)))

(defun nelisp-ime--key (session-id session event)
  "Normalize platform-neutral key EVENT and update SESSION-ID."
  (let ((style (plist-get session :input-style)))
    (cond
     ((eq style 'kana)
      (let ((kana (nelisp-ime-jis-kana-key
                   (plist-get event :code) (plist-get event :shift))))
        (unless kana (error "nelisp-ime: unmapped kana key"))
        (if (or (equal kana "゛") (equal kana "゜"))
            (progn
              (setq session
                    (plist-put session :reading
                               (nelisp-ime--apply-mark
                                (plist-get session :reading) kana)))
              (nelisp-ime--store session-id (nelisp-ime--reconvert session)))
          (nelisp-ime--insert session-id session kana))))
     ((eq style 'romaji)
      (let* ((result (nelisp-ime-romaji-step
                      (or (plist-get session :pending) "")
                      (plist-get event :key)))
             (text (plist-get result :text)))
        (setq session (plist-put session :pending
                                 (plist-get result :pending)))
        (when text
          (setq session
                (plist-put session :reading
                           (concat (plist-get session :reading) text))))
        (nelisp-ime--store session-id (nelisp-ime--reconvert session))))
     (t (error "nelisp-ime: unsupported input style %S" style)))))

(defun nelisp-ime--backspace (session-id session)
  "Remove the final character from SESSION-ID and reconvert."
  (let* ((pending (or (plist-get session :pending) ""))
         (reading (plist-get session :reading)))
    (if (> (length pending) 0)
        (setq session (plist-put session :pending
                                 (substring pending 0 (1- (length pending)))))
      (when (> (length reading) 0)
        (setq session (plist-put session :reading
                                 (substring reading 0 (1- (length reading)))))))
    (nelisp-ime--store session-id (nelisp-ime--reconvert session))))

(defun nelisp-ime--select-candidate (session-id session index)
  "Select candidate INDEX in SESSION-ID."
  (let* ((segments (plist-get session :segments))
         (active (or (plist-get session :active-segment) 0))
         (segment (nth active segments))
         (candidates (or (plist-get segment :candidates)
                         (plist-get session :candidates))))
    (unless (and (integerp index) (>= index 0) (< index (length candidates)))
      (error "nelisp-ime: candidate index out of range"))
    (setq session (plist-put session :candidate-index index))
    (if segment
        (progn
          (setq segment (plist-put segment :candidate (nth index candidates)))
          (setcar (nthcdr active segments) segment)
          (setq session (plist-put session :segments segments))
          (setq session
                (plist-put session :preedit
                           (nelisp-ime--segment-preedit segments))))
      (setq session (plist-put session :preedit (nth index candidates))))
    (nelisp-ime--store session-id session)))

(defun nelisp-ime--select-segment (session-id session index)
  "Make segment INDEX active in SESSION-ID."
  (let ((segments (plist-get session :segments)))
    (unless (and (integerp index) (>= index 0) (< index (length segments)))
      (error "nelisp-ime: segment index out of range"))
    (let ((candidates (plist-get (nth index segments) :candidates)))
      (setq session (plist-put session :active-segment index))
      (setq session (plist-put session :candidate-index 0))
      (setq session (plist-put session :candidates candidates))
      (nelisp-ime--store session-id session))))

(defun nelisp-ime--finish (session-id session commit-p)
  "Finish SESSION-ID, returning preedit when COMMIT-P is non-nil."
  (when (and commit-p (> (length (or (plist-get session :pending) "")) 0))
    (setq session
          (plist-put session :reading
                     (concat (plist-get session :reading)
                             (nelisp-ime-romaji-flush
                              (plist-get session :pending)))))
    (setq session (plist-put session :pending ""))
    (setq session (nelisp-ime--reconvert session)))
  (let ((commit (and commit-p (plist-get session :preedit)))
        (empty (list :id session-id
                     :input-style (plist-get session :input-style)
                     :context (plist-get session :context)
                     :engine (plist-get session :engine)
                     :reading "" :pending "" :preedit "" :segments nil
                     :candidates nil :active-segment 0 :candidate-index 0)))
    (when commit-p
      (let* ((engine (nelisp-ime--session-engine session))
             (learn (and engine (plist-get engine :learn))))
        (funcall (or learn #'nelisp-ime--learn-segments)
                 (plist-get session :segments))))
    (puthash session-id empty nelisp-ime-sessions)
    (nelisp-ime--snapshot empty commit)))

;;;###autoload
(defun nelisp-ime-feed (session-id event)
  "Apply normalized EVENT to SESSION-ID and return a composition snapshot.

Supported operations are :key, :insert, :backspace, :select-segment,
:select-candidate, :commit, and :cancel.  Platform adapters retain ownership
of native key codes and UI.

An engine registered with a :feed hook receives every EVENT before the
default composition pipeline and returns the snapshot itself."
  (let* ((session (nelisp-ime--session session-id))
         (engine (nelisp-ime--session-engine session))
         (feed (and engine (plist-get engine :feed)))
         (operation (plist-get event :op)))
    (cond
     (feed (funcall feed session-id session event))
     ((eq operation :key)
      (nelisp-ime--key session-id session event))
     ((eq operation :insert)
      (nelisp-ime--insert session-id session (plist-get event :text)))
     ((eq operation :backspace)
      (nelisp-ime--backspace session-id session))
     ((eq operation :select-candidate)
      (nelisp-ime--select-candidate session-id session
                                    (plist-get event :index)))
     ((eq operation :select-segment)
      (nelisp-ime--select-segment session-id session
                                  (plist-get event :index)))
     ((eq operation :commit)
      (nelisp-ime--finish session-id session t))
     ((eq operation :cancel)
      (nelisp-ime--finish session-id session nil))
     (t (error "nelisp-ime: unsupported operation %S" operation)))))

(provide 'nelisp-ime)
;;; nelisp-ime.el ends here
