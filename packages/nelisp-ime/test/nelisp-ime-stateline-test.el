;;; nelisp-ime-stateline-test.el --- Tests for the STATE line protocol -*- lexical-binding: t; -*-

(require 'ert)
(require 'nelisp-ime)
(require 'nelisp-ime-stateline)

(defmacro nelisp-ime-stateline-test--isolated (&rest body)
  "Run BODY with isolated sessions and dictionary."
  (declare (indent 0) (debug t))
  `(let ((nelisp-ime-sessions (make-hash-table :test 'equal))
         (nelisp-ime-learning (make-hash-table :test 'equal))
         (nelisp-ime-dictionary nil)
         ;; Hex encoding is a pure function, so a carried-over entry cannot
         ;; produce a wrong line -- but a test that counts entries would see
         ;; the previous test's.
         (nelisp-ime-stateline--candidate-hex (make-hash-table :test 'equal))
         (nelisp-ime-converter-function #'nelisp-ime-dictionary-convert))
     ,@body))

(defun nelisp-ime-stateline-test--field (line index)
  "Return field INDEX of a space-separated STATE LINE."
  (nth index (split-string line " ")))

(ert-deftest nelisp-ime-stateline-test-hex-matches-wire-format ()
  ;; Fixed-width 6-digit lowercase scalar hex, "-" for empty.
  (should (equal (nelisp-ime-stateline--hex "") "-"))
  (should (equal (nelisp-ime-stateline--hex "a") "000061"))
  (should (equal (nelisp-ime-stateline--hex "あ") "003042"))
  (should (equal (nelisp-ime-stateline--hex "ab") "000061000062"))
  ;; Above the BMP the top two digits are significant.
  (should (equal (nelisp-ime-stateline--hex (char-to-string #x1F600))
                 "01f600")))

(ert-deftest nelisp-ime-stateline-test-hello-and-engine-verbs ()
  (nelisp-ime-stateline-test--isolated
    (should (equal (nelisp-ime-stateline-dispatch "HELLO 1") "OK 1"))
    (should (string-prefix-p "ENGINES "
                             (nelisp-ime-stateline-dispatch "ENGINE LIST")))
    (should (string-prefix-p "ENGINE "
                             (nelisp-ime-stateline-dispatch "ENGINE CURRENT")))
    (let ((nelisp-ime-default-engine nelisp-ime-default-engine))
      (should (equal (nelisp-ime-stateline-dispatch "ENGINE SET dictionary")
                     "OK ENGINE dictionary"))
      (should (eq nelisp-ime-default-engine 'dictionary)))
    (should (equal (nelisp-ime-stateline-dispatch "ENGINE SET nope")
                   "ERR ENGINE nope"))))

(ert-deftest nelisp-ime-stateline-test-key-produces-state-line ()
  (nelisp-ime-stateline-test--isolated
    ;; A bare consonant stays pending; a vowel completes a kana.
    (let ((line (nelisp-ime-stateline-dispatch "KEY 107")))   ; k
      (should (string-prefix-p "STATE " line))
      (should (= (length (split-string line " ")) 8))
      (should (equal (nelisp-ime-stateline-test--field line 5) "00006b")))
    (let ((line (nelisp-ime-stateline-dispatch "KEY 97")))    ; a -> か
      (should (equal (nelisp-ime-stateline-test--field line 4) "00304b"))
      (should (equal (nelisp-ime-stateline-test--field line 5) "-")))))

(ert-deftest nelisp-ime-stateline-test-key-rejects-bad-codepoints ()
  (nelisp-ime-stateline-test--isolated
    (should (equal (nelisp-ime-stateline-dispatch "KEY abc") "ERR CODEPOINT"))
    (should (equal (nelisp-ime-stateline-dispatch "KEY 0") "ERR CODEPOINT"))
    (should (equal (nelisp-ime-stateline-dispatch "KEY 99999999")
                   "ERR CODEPOINT"))
    (should (equal (nelisp-ime-stateline-dispatch "NOPE") "ERR REQUEST"))))

(ert-deftest nelisp-ime-stateline-test-status-has-no-side-effects ()
  (nelisp-ime-stateline-test--isolated
    (nelisp-ime-stateline-dispatch "KEY 107")   ; k
    (nelisp-ime-stateline-dispatch "KEY 97")    ; a
    (let ((first (nelisp-ime-stateline-dispatch "STATUS"))
          (second (nelisp-ime-stateline-dispatch "STATUS")))
      (should (string-prefix-p "STATE " first))
      (should (equal first second)))))

(ert-deftest nelisp-ime-stateline-test-commit-and-reset ()
  (nelisp-ime-stateline-test--isolated
    (setq nelisp-ime-dictionary '(("かな" "仮名")))
    (nelisp-ime-stateline-dispatch "KEY 107")   ; k
    (nelisp-ime-stateline-dispatch "KEY 97")    ; a
    (nelisp-ime-stateline-dispatch "KEY 110")   ; n
    (nelisp-ime-stateline-dispatch "KEY 97")    ; a
    (should (string-prefix-p "STATE "
                             (nelisp-ime-stateline-dispatch "CONTROL COMMIT")))
    ;; After commit the composition is empty again.
    (let ((line (nelisp-ime-stateline-dispatch "STATUS")))
      (should (equal (nelisp-ime-stateline-test--field line 4) "-"))
      (should (equal (nelisp-ime-stateline-test--field line 3) "-1")))
    (should (string-prefix-p "STATE "
                             (nelisp-ime-stateline-dispatch "RESET")))))

(ert-deftest nelisp-ime-stateline-test-convert-steps-candidates ()
  (nelisp-ime-stateline-test--isolated
    (setq nelisp-ime-dictionary '(("はし" "橋" "箸" "端")))
    (nelisp-ime-session-open nelisp-ime-stateline--session-id
                             '(:input-style romaji))
    (nelisp-ime-feed nelisp-ime-stateline--session-id
                     '(:op :insert :text "はし"))
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL CONVERT")))
      ;; Stepped from candidate 0 to 1.
      (should (equal (nelisp-ime-stateline-test--field line 6) "1")))
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL PREVIOUS")))
      (should (equal (nelisp-ime-stateline-test--field line 6) "0")))))

(ert-deftest nelisp-ime-stateline-test-convert-without-candidates-reports-state ()
  (nelisp-ime-stateline-test--isolated
    (let ((line (nelisp-ime-stateline-dispatch "CONTROL CONVERT")))
      (should (string-prefix-p "STATE " line)))))

(ert-deftest nelisp-ime-stateline-test-maintenance-verbs ()
  (nelisp-ime-stateline-test--isolated
    (should (equal (nelisp-ime-stateline-dispatch "GC") "OK GC"))
    (should (string-prefix-p "OK COMPACT"
                             (nelisp-ime-stateline-dispatch "COMPACT")))
    (should (equal (nelisp-ime-stateline-dispatch "QUIT") "OK BYE"))))

(ert-deftest nelisp-ime-stateline-test-engine-failure-degrades ()
  (nelisp-ime-stateline-test--isolated
    (let ((nelisp-ime-engines (copy-hash-table nelisp-ime-engines))
          (nelisp-ime-fail-open nil))
      (nelisp-ime-engine-register
       'boom-stateline
       :feed (lambda (_id _session _event) (error "engine exploded")))
      (nelisp-ime-session-open nelisp-ime-stateline--session-id
                               '(:input-style romaji :engine boom-stateline))
      ;; With fail-open disabled the engine signals; the protocol must still
      ;; answer a line rather than propagate.
      (should (equal (nelisp-ime-stateline-dispatch "KEY 97") "ERR INTERNAL")))))

(defun nelisp-ime-stateline-test--candidates-uncached (snapshot)
  "Build SNAPSHOT's candidate field without consulting the cache."
  (let ((candidates (plist-get snapshot :candidates)))
    (if (or (null candidates) (= (length candidates) 0))
        "-"
      (let ((parts nil) (index (1- (length candidates))))
        (while (>= index 0)
          (push (nelisp-ime-stateline--hex (aref candidates index)) parts)
          (setq index (1- index)))
        (mapconcat #'identity parts ",")))))

(ert-deftest nelisp-ime-stateline-test-candidate-hex-cache-matches-uncached ()
  "The cached candidate field is the field an uncached encoder builds.
The cache exists to skip work, so the only thing that matters about it is
that skipping the work changes nothing on the wire."
  (nelisp-ime-stateline-test--isolated
    (setq nelisp-ime-dictionary '(("はし" "橋" "箸" "端")))
    (nelisp-ime-session-open "s")
    (let ((snapshot (nelisp-ime-feed "s" '(:op :insert :text "はし"))))
      ;; Twice: the first call fills the cache, the second reads it, and both
      ;; must agree with the uncached build.
      (should (equal (nelisp-ime-stateline--candidates snapshot)
                     (nelisp-ime-stateline-test--candidates-uncached snapshot)))
      (should (equal (nelisp-ime-stateline--candidates snapshot)
                     (nelisp-ime-stateline-test--candidates-uncached snapshot))))))

(ert-deftest nelisp-ime-stateline-test-candidate-hex-cache-is-consulted ()
  "The cache is actually read, so the agreement test above is not vacuous.
Poisoning one entry must change the field: if the encoder ignored the
cache, this would pass unchanged and the test above would be proving
nothing about the cache at all."
  (nelisp-ime-stateline-test--isolated
    (setq nelisp-ime-dictionary '(("はし" "橋" "箸")))
    (nelisp-ime-session-open "s")
    (let* ((snapshot (nelisp-ime-feed "s" '(:op :insert :text "はし")))
           (honest (nelisp-ime-stateline--candidates snapshot)))
      (should (> (hash-table-count nelisp-ime-stateline--candidate-hex) 0))
      (puthash "橋" "poisoned" nelisp-ime-stateline--candidate-hex)
      (should-not (equal (nelisp-ime-stateline--candidates snapshot) honest))
      ;; And clearing it restores the honest answer, which is what
      ;; `nelisp-ime-stateline--cache-clear' is for.
      (nelisp-ime-stateline--cache-clear)
      (should (= (hash-table-count nelisp-ime-stateline--candidate-hex) 0))
      (should (equal (nelisp-ime-stateline--candidates snapshot) honest)))))

(ert-deftest nelisp-ime-stateline-test-candidate-hex-cache-keyed-per-surface ()
  "Two surfaces sharing no prefix get their own entries.
A cache keyed by anything coarser than the surface -- the segment, the
reading, the index -- would answer one surface with another's hex."
  (nelisp-ime-stateline-test--isolated
    (setq nelisp-ime-dictionary '(("はし" "橋" "箸")))
    (nelisp-ime-session-open "s")
    (nelisp-ime-stateline--candidates
     (nelisp-ime-feed "s" '(:op :insert :text "はし")))
    (should (equal (gethash "橋" nelisp-ime-stateline--candidate-hex)
                   (nelisp-ime-stateline--hex "橋")))
    (should (equal (gethash "箸" nelisp-ime-stateline--candidate-hex)
                   (nelisp-ime-stateline--hex "箸")))
    (should-not (equal (gethash "橋" nelisp-ime-stateline--candidate-hex)
                       (gethash "箸" nelisp-ime-stateline--candidate-hex)))))

(ert-deftest nelisp-ime-stateline-test-session-omits-the-segments-it-never-reads ()
  "The protocol's own session runs at `candidates-only'.
This file reads :mode :cursor :composition-start :preedit :pending
:candidate-index and :candidates, and never :segments -- building it was
~40% of a keystroke.  Asserted on the session the protocol opens for
itself, because that is the one the Windows host drives."
  (nelisp-ime-stateline-test--isolated
    (setq nelisp-ime-dictionary '(("はし" "橋" "箸")))
    (nelisp-ime-stateline-dispatch "RESET")
    (nelisp-ime-stateline-dispatch "KEY 104")   ; h
    (nelisp-ime-stateline-dispatch "KEY 97")    ; a
    (let ((session (gethash nelisp-ime-stateline--session-id
                            nelisp-ime-sessions)))
      (should (eq (plist-get session :detail) 'candidates-only))
      (let ((snapshot (nelisp-ime-session-status
                       nelisp-ime-stateline--session-id)))
        (should (equal (plist-get snapshot :segments) []))))))

(provide 'nelisp-ime-stateline-test)
;;; nelisp-ime-stateline-test.el ends here
