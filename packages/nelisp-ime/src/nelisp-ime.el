;;; nelisp-ime.el --- Portable NeLisp input method engine core  -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; OS-independent input method sessions.  Platform adapters normalize native
;; key events before calling this package and render the returned snapshot with
;; InputMethodKit, Fcitx/IBus, or TSF.

;;; Code:

(require 'cl-lib)
(require 'nelisp-ime-input)

(defgroup nelisp-ime nil
  "Portable input method engine core."
  :group 'nelisp
  :prefix "nelisp-ime-")

(defvar nelisp-ime-sessions (make-hash-table :test 'equal)
  "Active input sessions keyed by platform-supplied string identifiers.")

(defvar nelisp-ime-dictionary nil
  "Alist mapping readings to ordered conversion candidates.

A candidate may be a surface string or a plist containing :surface and
:cost.  Lower costs win.  String candidates receive costs from their order.")

(defvar nelisp-ime-dictionary-index (make-hash-table :test 'equal)
  "Indexed dictionary populated by `nelisp-ime-dictionary-load-skk'.")

(defvar nelisp-ime-system-candidates
  '(("は" "は") ("へ" "へ") ("を" "を") ("に" "に") ("の" "の")
    ("が" "が") ("と" "と") ("で" "で") ("も" "も") ("や" "や")
    ("か" "か") ("ね" "ね") ("よ" "よ") ("です" "です")
    ("ます" "ます") ("でした" "でした") ("ました" "ました")
    ("する" "する") ("します" "します") ("して" "して") ("した" "した")
    ("いる" "いる") ("ある" "ある") ("ない" "ない")
    ("いい" "いい"))
  "Readings whose grammatical kana form must precede dictionary homophones.")

(defvar nelisp-ime-unknown-cost 10000
  "Cost assigned to one unknown kana character in lattice conversion.")

(defconst nelisp-ime-infinity 1000000000000
  "Portable unreachable-path cost for the conversion lattice.")

(defvar nelisp-ime-learning (make-hash-table :test 'equal)
  "Selection frequencies keyed by a reading and surface pair.")

(defvar nelisp-ime-learning-weight 100
  "Cost reduction applied for each learned candidate selection.")

(defvar nelisp-ime-converter-function #'nelisp-ime-lattice-convert
  "Function called with READING and CONTEXT to produce a conversion plist.")

(defun nelisp-ime--check-session-id (session-id)
  "Require SESSION-ID to be a non-empty string."
  (unless (and (stringp session-id) (> (length session-id) 0))
    (error "nelisp-ime: session id must be a non-empty string")))

(defun nelisp-ime--session (session-id)
  "Return SESSION-ID state or signal an error when it is not open."
  (or (gethash session-id nelisp-ime-sessions)
      (error "nelisp-ime: unknown session %s" session-id)))

(defun nelisp-ime-dictionary-convert (reading _context)
  "Convert READING using `nelisp-ime-dictionary'.

The first candidate is the live preedit.  An unknown reading remains kana.
This exact-reading converter is intentionally small; a lattice converter can
replace it without changing the session or platform adapter APIs."
  (let ((candidates (cdr (assoc reading nelisp-ime-dictionary))))
    (list :preedit (or (car candidates) reading)
          :candidates (or candidates (and (> (length reading) 0)
                                          (list reading)))
          :segments (and (> (length reading) 0)
                         (list (list :from 0 :to (length reading)
                                     :reading reading
                                     :candidate (or (car candidates)
                                                    reading)))))))

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

(defun nelisp-ime--dictionary-candidates (reading)
  "Return normalized dictionary candidates for READING."
  (let ((items (append (cdr (assoc reading nelisp-ime-system-candidates))
                       (or (gethash reading nelisp-ime-dictionary-index)
                           (cdr (assoc reading nelisp-ime-dictionary)))))
        (rank 0)
        seen
        result)
    (dolist (item items)
      (let* ((candidate (nelisp-ime--candidate-normalize item rank))
             (surface (plist-get candidate :surface))
             (learned (nelisp-ime-learning-count reading surface)))
        (unless (member surface seen)
          (push surface seen)
          (setq candidate
                (plist-put candidate :cost
                           (- (plist-get candidate :cost)
                              (* learned nelisp-ime-learning-weight))))
          (push candidate result)))
      (setq rank (1+ rank)))
    (sort result (lambda (left right)
                   (< (plist-get left :cost) (plist-get right :cost))))))

(defun nelisp-ime--skk-candidate (value)
  "Return plain candidate text from SKK VALUE, or nil if unsupported."
  (let* ((annotation (string-match ";" value))
         (surface (if annotation (substring value 0 annotation) value)))
    (when (and (> (length surface) 0)
               (not (= (aref surface 0) 40)))
      surface)))

(defconst nelisp-ime--okuri-forms
  '(("k" ("く" . "く") ("かない" . "かない") ("きます" . "きます")
     ("いた" . "いた") ("いて" . "いて") ("けば" . "けば") ("こう" . "こう"))
    ("g" ("ぐ" . "ぐ") ("がない" . "がない") ("ぎます" . "ぎます")
     ("いだ" . "いだ") ("いで" . "いで") ("げば" . "げば") ("ごう" . "ごう"))
    ("s" ("す" . "す") ("さない" . "さない") ("します" . "します")
     ("した" . "した") ("して" . "して") ("せば" . "せば") ("そう" . "そう"))
    ("t" ("つ" . "つ") ("たない" . "たない") ("ちます" . "ちます")
     ("った" . "った") ("って" . "って") ("てば" . "てば") ("とう" . "とう"))
    ("n" ("ぬ" . "ぬ") ("なない" . "なない") ("にます" . "にます")
     ("んだ" . "んだ") ("んで" . "んで") ("ねば" . "ねば") ("のう" . "のう"))
    ("b" ("ぶ" . "ぶ") ("ばない" . "ばない") ("びます" . "びます")
     ("んだ" . "んだ") ("んで" . "んで") ("べば" . "べば") ("ぼう" . "ぼう"))
    ("m" ("む" . "む") ("まない" . "まない") ("みます" . "みます")
     ("んだ" . "んだ") ("んで" . "んで") ("めば" . "めば") ("もう" . "もう"))
    ("w" ("う" . "う") ("わない" . "わない") ("います" . "います")
     ("った" . "った") ("って" . "って") ("えば" . "えば") ("おう" . "おう"))
    ("r" ("る" . "る") ("らない" . "らない") ("ります" . "ります")
     ("った" . "った") ("って" . "って") ("れば" . "れば") ("ろう" . "ろう"))
    ("i" ("い" . "い") ("くない" . "くない") ("かった" . "かった")
     ("くて" . "くて") ("ければ" . "ければ") ("そう" . "そう")))
  "Conservative conjugation forms used to expand SKK okuri entries.")

(defun nelisp-ime--skk-expand-okuri (reading candidates table)
  "Expand okuri-ari READING and CANDIDATES into TABLE."
  (let* ((end (1- (length reading)))
         (base (substring reading 0 end))
         (code (substring reading end))
         (forms (cdr (assoc code nelisp-ime--okuri-forms))))
    (dolist (form forms)
      (let ((key (concat base (car form)))
            surfaces)
        (dolist (candidate candidates)
          (push (concat candidate (cdr form)) surfaces))
        (puthash key (append (gethash key table) (nreverse surfaces)) table)))))

(defun nelisp-ime--skk-line (line table expand-okuri)
  "Parse one SKK dictionary LINE into TABLE."
  (unless (or (= (length line) 0) (= (aref line 0) ?\;))
    (let ((space (string-match " " line)))
      (when space
        (let* ((reading (substring line 0 space))
               (body (substring line (1+ space)))
               (parts (split-string body "/" t))
               candidates)
          (dolist (part parts)
            (let ((candidate (nelisp-ime--skk-candidate part)))
              (when candidate (push candidate candidates))))
          (setq candidates (nreverse candidates))
          (when candidates
            (if (and (> (length reading) 0)
                     (< (aref reading (1- (length reading))) 128))
                (when expand-okuri
                  (nelisp-ime--skk-expand-okuri reading candidates table))
              (puthash reading candidates table))))))))

(defun nelisp-ime-dictionary-install (entries)
  "Install portable dictionary ENTRIES and return their count.

ENTRIES is an alist whose keys are readings and whose values are candidate
lists.  This representation can be loaded by standalone NeLisp without
depending on editor buffer primitives."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (entry entries)
      (puthash (car entry) (cdr entry) table))
    (setq nelisp-ime-dictionary-index table)
    (hash-table-count table)))

;;;###autoload
(defun nelisp-ime-dictionary-load-skk (file &optional coding expand-okuri)
  "Load SKK dictionary FILE into an indexed table and return entry count.

CODING defaults to euc-jp, the canonical SKK distribution encoding.  Lisp
expression candidates are ignored; plain candidates and annotations are safe."
  (let ((coding-system-for-read (or coding 'euc-jp))
        (table (make-hash-table :test 'equal)))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (while (< (point) (point-max))
        (let ((start (point))
              (end (line-end-position)))
          (forward-line 1)
          (nelisp-ime--skk-line
           (buffer-substring-no-properties start end)
           table expand-okuri))))
    (setq nelisp-ime-dictionary-index table)
    (hash-table-count table)))

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

(defun nelisp-ime--lattice-edges (reading from)
  "Return conversion edges beginning at FROM in READING."
  (let ((remaining (- (length reading) from))
        (size 1)
        edges)
    (while (<= size remaining)
      (let* ((key (substring reading from (+ from size)))
             (candidates (nelisp-ime--dictionary-candidates key)))
        (when candidates
          (push (list :from from :to (+ from size) :reading key
                      :candidates candidates
                      :surface (plist-get (car candidates) :surface)
                      :cost (plist-get (car candidates) :cost))
                edges)))
      (setq size (1+ size)))
    (when (> remaining 0)
      (let ((kana (substring reading from (1+ from))))
        (push (list :from from :to (1+ from) :reading kana
                    :candidates (list (list :surface kana
                                            :cost nelisp-ime-unknown-cost))
                    :surface kana :cost nelisp-ime-unknown-cost)
              edges)))
    edges))

(defun nelisp-ime--segment-public (edge)
  "Convert internal lattice EDGE to a public segment plist."
  (list :from (plist-get edge :from)
        :to (plist-get edge :to)
        :reading (plist-get edge :reading)
        :candidate (plist-get edge :surface)
        :candidates (mapcar (lambda (item) (plist-get item :surface))
                            (plist-get edge :candidates))))

(defun nelisp-ime-lattice-convert (reading _context)
  "Convert READING through a minimum-cost dictionary lattice."
  (if (= (length reading) 0)
      '(:preedit "" :candidates nil :segments nil)
    (let* ((size (length reading))
           (infinity nelisp-ime-infinity)
           (costs (make-vector (1+ size) infinity))
           (paths (make-vector (1+ size) nil)))
      (aset costs 0 0)
      (let ((position 0))
        (while (< position size)
          (unless (= (aref costs position) infinity)
            (dolist (edge (nelisp-ime--lattice-edges reading position))
              (let* ((to (plist-get edge :to))
                     (cost (+ (aref costs position)
                              (plist-get edge :cost))))
                (when (< cost (aref costs to))
                  (aset costs to cost)
                  (aset paths to (append (aref paths position)
                                         (list edge)))))))
          (setq position (1+ position))))
      (let* ((path (aref paths size))
             (segments (mapcar #'nelisp-ime--segment-public path))
             (preedit (mapconcat (lambda (edge)
                                   (plist-get edge :surface))
                                 path ""))
             (first (car segments)))
        (list :preedit preedit
              :candidates (plist-get first :candidates)
              :segments segments
              :cost (aref costs size))))))

(defun nelisp-ime--segment-preedit (segments)
  "Concatenate selected candidates from SEGMENTS."
  (mapconcat (lambda (segment) (plist-get segment :candidate)) segments ""))

(defun nelisp-ime--reconvert (session)
  "Recompute live conversion fields in SESSION and return SESSION."
  (let* ((reading (plist-get session :reading))
         (context (plist-get session :context))
         (conversion (funcall nelisp-ime-converter-function reading context)))
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

OPTIONS may contain :input-style and :context.  Input-style is metadata for
the platform adapter; physical key layout normalization stays outside core."
  (nelisp-ime--check-session-id session-id)
  (let ((session (list :id session-id
                       :input-style (or (plist-get options :input-style) 'kana)
                       :context (plist-get options :context)
                       :reading ""
                       :pending ""
                       :preedit ""
                       :segments nil
                       :candidates nil
                       :active-segment 0
                       :candidate-index 0)))
    (puthash session-id session nelisp-ime-sessions)
    (nelisp-ime--snapshot session)))

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
                     :reading "" :pending "" :preedit "" :segments nil
                     :candidates nil :active-segment 0 :candidate-index 0)))
    (when commit-p (nelisp-ime--learn-segments (plist-get session :segments)))
    (puthash session-id empty nelisp-ime-sessions)
    (nelisp-ime--snapshot empty commit)))

;;;###autoload
(defun nelisp-ime-feed (session-id event)
  "Apply normalized EVENT to SESSION-ID and return a composition snapshot.

Supported operations are :key, :insert, :backspace, :select-segment,
:select-candidate, :commit, and :cancel.  Platform adapters retain ownership
of native key codes and UI."
  (let* ((session (nelisp-ime--session session-id))
         (operation (plist-get event :op)))
    (cond
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
