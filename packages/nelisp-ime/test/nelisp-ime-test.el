;;; nelisp-ime-test.el --- Tests for the NeLisp IME framework core  -*- lexical-binding: t; -*-

;; These tests exercise the engine-agnostic framework only.  The bundled
;; lattice engine has its own suite in the nelisp-ime-lattice package.

(require 'ert)
(require 'nelisp-ime)

(defmacro nelisp-ime-test--isolated (&rest body)
  "Run BODY with isolated sessions and dictionary."
  (declare (indent 0) (debug t))
  `(let ((nelisp-ime-sessions (make-hash-table :test 'equal))
         (nelisp-ime-learning (make-hash-table :test 'equal))
         (nelisp-ime-dictionary nil)
         (nelisp-ime-converter-function #'nelisp-ime-dictionary-convert))
     ,@body))

(ert-deftest nelisp-ime-test-open-and-insert-kana ()
  (nelisp-ime-test--isolated
    (nelisp-ime-session-open "mac:1" '(:input-style kana))
    (let ((result (nelisp-ime-feed "mac:1" '(:op :insert :text "かな"))))
      (should (equal (plist-get result :reading) "かな"))
      (should (equal (plist-get result :preedit) "かな")))))

(ert-deftest nelisp-ime-test-live-converts-after-each-insert ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-dictionary
          '(("きょう" "今日" "教") ("きょ" "許")))
    (nelisp-ime-session-open "s")
    (should (equal (plist-get
                    (nelisp-ime-feed "s" '(:op :insert :text "きょ"))
                    :preedit)
                   "許"))
    (should (equal (plist-get
                    (nelisp-ime-feed "s" '(:op :insert :text "う"))
                    :preedit)
                   "今日"))))

(ert-deftest nelisp-ime-test-select-and-commit-candidate ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-dictionary '(("はし" "橋" "箸" "端")))
    (nelisp-ime-session-open "s")
    (nelisp-ime-feed "s" '(:op :insert :text "はし"))
    (let ((selected (nelisp-ime-feed
                     "s" '(:op :select-candidate :index 1))))
      (should (equal (plist-get selected :preedit) "箸")))
    (let ((committed (nelisp-ime-feed "s" '(:op :commit))))
      (should (equal (plist-get committed :commit) "箸"))
      (should (equal (plist-get committed :preedit) "")))))

(ert-deftest nelisp-ime-test-backspace-reconverts ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-dictionary '(("か" "蚊") ("かな" "仮名")))
    (nelisp-ime-session-open "s")
    (nelisp-ime-feed "s" '(:op :insert :text "かな"))
    (let ((result (nelisp-ime-feed "s" '(:op :backspace))))
      (should (equal (plist-get result :reading) "か"))
      (should (equal (plist-get result :preedit) "蚊")))))

(ert-deftest nelisp-ime-test-cancel-and-session-isolation ()
  (nelisp-ime-test--isolated
    (nelisp-ime-session-open "linux:1")
    (nelisp-ime-session-open "windows:1")
    (nelisp-ime-feed "linux:1" '(:op :insert :text "あ"))
    (nelisp-ime-feed "windows:1" '(:op :insert :text "い"))
    (should-not (plist-get (nelisp-ime-feed "linux:1" '(:op :cancel))
                           :commit))
    (should (equal
             (plist-get (nelisp-ime-feed "windows:1" '(:op :commit)) :commit)
             "い"))))

(ert-deftest nelisp-ime-test-rejects-invalid-events ()
  (nelisp-ime-test--isolated
    (should-error (nelisp-ime-session-open "") :type 'error)
    (should-error (nelisp-ime-feed "missing" '(:op :commit))
                  :type 'error)
    (nelisp-ime-session-open "s")
    (should-error (nelisp-ime-feed "s" '(:op :insert :text 1))
                  :type 'error)
    (should-error (nelisp-ime-feed "s" '(:op :unknown))
                  :type 'error)))

(ert-deftest nelisp-ime-test-jis-kana-physical-keys-and-marks ()
  (nelisp-ime-test--isolated
    (nelisp-ime-session-open "s" '(:input-style kana))
    (nelisp-ime-feed "s" '(:op :key :code "KeyT"))
    (let ((result (nelisp-ime-feed
                   "s" '(:op :key :code "BracketLeft"))))
      (should (equal (plist-get result :reading) "が")))
    (let ((result (nelisp-ime-feed
                   "s" '(:op :key :code "KeyZ" :shift t))))
      (should (equal (plist-get result :reading) "がっ")))))

(ert-deftest nelisp-ime-test-jis-kana-specific-and-punctuation-keys ()
  (should (equal (nelisp-ime-jis-kana-key "IntlYen" nil) "ー"))
  (should (equal (nelisp-ime-jis-kana-key "Backslash" nil) "む"))
  (should (equal (nelisp-ime-jis-kana-key "IntlRo" nil) "ろ"))
  (should (equal (nelisp-ime-jis-kana-key "Comma" t) "、"))
  (should (equal (nelisp-ime-jis-kana-key "Period" t) "。"))
  (should (equal (nelisp-ime-jis-kana-key "Slash" t) "・")))

(ert-deftest nelisp-ime-test-romaji-incremental-normalization ()
  (nelisp-ime-test--isolated
    (nelisp-ime-session-open "s" '(:input-style romaji))
    (dolist (key '("k" "y" "o" "u"))
      (nelisp-ime-feed "s" `(:op :key :key ,key)))
    (let ((result (nelisp-ime-feed "s" '(:op :key :key "h"))))
      (should (equal (plist-get result :reading) "きょう"))
      (should (equal (plist-get result :preedit) "きょうh"))
      (should (equal (plist-get result :pending) "h")))
    (let ((result (nelisp-ime-feed "s" '(:op :key :key "a"))))
      (should (equal (plist-get result :reading) "きょうは"))
      (should (equal (plist-get result :pending) "")))))

(ert-deftest nelisp-ime-test-romaji-double-consonant-and-n ()
  (should (equal (nelisp-ime-romaji-step "k" "k")
                 '(:text "っ" :pending "k")))
  (let ((first (nelisp-ime-romaji-step "" "n")))
    (should (equal (plist-get first :pending) "n"))
    (should (equal (nelisp-ime-romaji-step "n" "n")
                   '(:text "ん" :pending "")))))

(ert-deftest nelisp-ime-test-romaji-pending-backspace-and-commit ()
  (nelisp-ime-test--isolated
    (nelisp-ime-session-open "s" '(:input-style romaji))
    (nelisp-ime-feed "s" '(:op :key :key "k"))
    (let ((result (nelisp-ime-feed "s" '(:op :backspace))))
      (should (equal (plist-get result :preedit) ""))
      (should (equal (plist-get result :pending) "")))
    (nelisp-ime-feed "s" '(:op :key :key "n"))
    (let ((result (nelisp-ime-feed "s" '(:op :commit))))
      (should (equal (plist-get result :commit) "ん")))))

(ert-deftest nelisp-ime-test-commit-learns-selected-candidate ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-dictionary '(("はし" "橋" "箸")))
    (nelisp-ime-session-open "s")
    (nelisp-ime-feed "s" '(:op :insert :text "はし"))
    (nelisp-ime-feed "s" '(:op :select-candidate :index 1))
    (nelisp-ime-feed "s" '(:op :commit))
    (should (= (nelisp-ime-learning-count "はし" "箸") 1))))

(ert-deftest nelisp-ime-test-learning-round-trips-without-eval ()
  (nelisp-ime-test--isolated
    (let* ((directory (make-temp-file "nelisp-ime-learning-" t))
           (file (expand-file-name "learning.eldata" directory)))
      (unwind-protect
          (progn
            (puthash (nelisp-ime--learning-key "かな" "仮名") 3
                     nelisp-ime-learning)
            (nelisp-ime-learning-save file)
            (setq nelisp-ime-learning (make-hash-table :test 'equal))
            (should (= (nelisp-ime-learning-load file) 1))
            (should (= (nelisp-ime-learning-count "かな" "仮名") 3)))
        (delete-directory directory t)))))

(ert-deftest nelisp-ime-test-learning-import-validates-data ()
  (nelisp-ime-test--isolated
    (should-error (nelisp-ime-learning-import '(("key" "value" -1)))
                  :type 'error)
    (should-error (nelisp-ime-learning-import '((symbol "value" 1)))
                  :type 'error)))

(ert-deftest nelisp-ime-test-snapshot-truncates-candidates ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-dictionary '(("は" "端" "歯" "葉" "刃" "派")))
    (let ((nelisp-ime-candidate-limit 2))
      (nelisp-ime-session-open "s")
      (let ((result (nelisp-ime-feed "s" '(:op :insert :text "は"))))
        (should (equal (plist-get result :candidates) ["端" "歯"]))))
    (let ((nelisp-ime-candidate-limit nil))
      (nelisp-ime-session-open "s")
      (let ((result (nelisp-ime-feed "s" '(:op :insert :text "は"))))
        (should (= (length (plist-get result :candidates)) 5))))))

(ert-deftest nelisp-ime-test-session-selects-registered-engine ()
  (nelisp-ime-test--isolated
    (let ((nelisp-ime-engines (copy-hash-table nelisp-ime-engines)))
      (nelisp-ime-engine-register
       'upcase-test
       :convert (lambda (reading _context)
                  (list :preedit (upcase reading)
                        :candidates (list (upcase reading))
                        :segments nil)))
      (nelisp-ime-session-open "s" '(:input-style romaji :engine upcase-test))
      (should (equal (plist-get
                      (nelisp-ime-feed "s" '(:op :insert :text "abc"))
                      :preedit)
                     "ABC")))))

(ert-deftest nelisp-ime-test-feed-hook-intercepts-events ()
  (nelisp-ime-test--isolated
    (let ((nelisp-ime-engines (copy-hash-table nelisp-ime-engines)))
      (nelisp-ime-engine-register
       'modal-test
       :feed (lambda (_session-id _session event)
               (list :consumed t
                     :preedit (format "modal:%s" (plist-get event :op)))))
      (nelisp-ime-session-open "s" '(:engine modal-test))
      (should (equal (plist-get
                      (nelisp-ime-feed "s" '(:op :insert :text "x"))
                      :preedit)
                     "modal::insert")))))

(ert-deftest nelisp-ime-test-open-rejects-unknown-engine ()
  (nelisp-ime-test--isolated
    (should-error (nelisp-ime-session-open "s" '(:engine no-such-engine))
                  :type 'error)))

(ert-deftest nelisp-ime-test-default-engine-used-without-converter ()
  (nelisp-ime-test--isolated
    (setq nelisp-ime-converter-function nil)
    (let ((nelisp-ime-engines (copy-hash-table nelisp-ime-engines))
          (nelisp-ime-default-engine 'default-test))
      (nelisp-ime-engine-register
       'default-test
       :convert (lambda (reading _context)
                  (list :preedit (concat "d:" reading)
                        :candidates (list reading)
                        :segments nil)))
      (nelisp-ime-session-open "s")
      (should (equal (plist-get
                      (nelisp-ime-feed "s" '(:op :insert :text "はし"))
                      :preedit)
                     "d:はし")))))

(ert-deftest nelisp-ime-test-engine-learn-hook-replaces-framework-learning ()
  (nelisp-ime-test--isolated
    (let ((nelisp-ime-engines (copy-hash-table nelisp-ime-engines))
          (learned nil))
      (nelisp-ime-engine-register
       'learn-test
       :convert #'nelisp-ime-dictionary-convert
       :learn (lambda (segments) (setq learned segments)))
      (setq nelisp-ime-dictionary '(("はし" "橋")))
      (nelisp-ime-session-open "s" '(:engine learn-test))
      (nelisp-ime-feed "s" '(:op :insert :text "はし"))
      (nelisp-ime-feed "s" '(:op :commit))
      (should learned)
      (should (= (nelisp-ime-learning-count "はし" "橋") 0)))))

(provide 'nelisp-ime-test)
;;; nelisp-ime-test.el ends here
