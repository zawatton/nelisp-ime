;; Native GTK4 key-event probe: OS events enter callbacks compiled by NeLisp AOT.
;; This demonstrates widget delivery only; it does not provide IME conversion.
(seq
 (data-blob title "NeLisp GTK4 OS probe\0" rodata)
 (data-blob sig_close "close-request\0" rodata)
 (data-blob sig_key "key-pressed\0" rodata)
 (data-blob sig_timeout "timeout\0" rodata)
 (data-blob trace_pre "PREEDIT: %s\n\0" rodata)
 (data-blob trace_commit "COMMIT: %s\n\0" rodata)
 (data-blob empty_text "\0" rodata)

 ;; State layout: [loop, committed label, preedit label, timer id, preedit bytes].
 ;; The 512-byte text buffer starts at offset 32; UTF-8 scratch is at 544.
 (defun trace-widget (format label)
   (seq
    ;; Read back the actual native widget text before reporting it.
    (extern-call g_print format (extern-call gtk_label_get_text label))
    0))

 (defun on_key (controller keyval keycode state ctx)
   (let ((pre (+ ctx 32))
         (cp (extern-call gdk_keyval_to_unicode keyval)))
     (cond
      ((= keyval #xff1b) (seq (extern-call g_main_loop_quit (ptr-read-u64 ctx 0)) 1))
      ((= keyval #xff0d)
       (let ((committed-text (extern-call gtk_label_get_text (ptr-read-u64 ctx 16))))
         (seq
          (extern-call gtk_label_set_text (ptr-read-u64 ctx 8) committed-text)
          (trace-widget (data-addr trace_commit) (ptr-read-u64 ctx 8))
          (extern-call gtk_label_set_text (ptr-read-u64 ctx 16) (data-addr empty_text))
          (trace-widget (data-addr trace_pre) (ptr-read-u64 ctx 16))
          (ptr-write-u8 pre 0 0)
          1)))
      ((= keyval #xff08)
       (let ((n (extern-call strlen (extern-call gtk_label_get_text (ptr-read-u64 ctx 16)))))
         (seq
          (when (> n 0)
            (let ((i (- n 1)))
              (seq
               (while (and (> i 0) (= (logand (ptr-read-u8 pre i) 192) 128))
                 (setq i (- i 1)))
               (ptr-write-u8 pre i 0))))
          (extern-call gtk_label_set_text (ptr-read-u64 ctx 16) pre)
          (trace-widget (data-addr trace_pre) (ptr-read-u64 ctx 16))
          1)))
      ((and (> cp 0) (= (logand state 469762060) 0))
       (let ((utf (+ ctx 544)))
         (let ((count (extern-call g_unichar_to_utf8 cp utf)))
           (let ((n (extern-call strlen (extern-call gtk_label_get_text (ptr-read-u64 ctx 16)))))
             (if (and (> count 0) (< (+ n count) 511))
                 (seq
                  (let ((i 0))
                    (while (< i count)
                      (seq (ptr-write-u8 pre (+ n i) (ptr-read-u8 utf i))
                           (setq i (+ i 1)))))
                  (ptr-write-u8 pre (+ n count) 0)
                  (extern-call gtk_label_set_text (ptr-read-u64 ctx 16) pre)
                  (trace-widget (data-addr trace_pre) (ptr-read-u64 ctx 16))
                  1)
               0)))))
      (t 0))))

 (defun on_timeout (ctx)
   (seq (ptr-write-u64 ctx 24 0)
        (extern-call g_main_loop_quit (ptr-read-u64 ctx 0))
        0))

 (defun on_close (window ctx)
   (seq (extern-call g_main_loop_quit (ptr-read-u64 ctx 0)) 1))

 (defun main ()
   (seq
    (extern-call gtk_init)
    (let ((ctx (extern-call g_malloc0 1600)))
      (seq
       (let ((window (extern-call gtk_window_new))
             (pre (extern-call gtk_label_new (data-addr empty_text)))
             (out (extern-call gtk_label_new (data-addr empty_text)))
             (box (extern-call gtk_box_new 1 8))
             (loop (extern-call g_main_loop_new 0 0))
             (keys (extern-call gtk_event_controller_key_new)))
         (seq
          (ptr-write-u64 ctx 0 loop)
          (ptr-write-u64 ctx 8 out)
          (ptr-write-u64 ctx 16 pre)
          (ptr-write-u64 ctx 24 0)
          (extern-call gtk_window_set_title window (data-addr title))
          (extern-call gtk_box_append box pre)
          (extern-call gtk_box_append box out)
          (extern-call gtk_window_set_child window box)
          (extern-call gtk_widget_add_controller window keys)
          (extern-call g_signal_connect_data keys (data-addr sig_key) (addr-of on_key) ctx 0 0)
          (extern-call g_signal_connect_data window (data-addr sig_close) (addr-of on_close) ctx 0 0)
          (ptr-write-u64 ctx 24 (extern-call g_timeout_add 30000 (addr-of on_timeout) ctx))
          (extern-call gtk_window_present window)
          (extern-call g_main_loop_run loop)
          (when (> (ptr-read-u64 ctx 24) 0)
            (extern-call g_source_remove (ptr-read-u64 ctx 24)))
          (extern-call gtk_window_destroy window)
          (extern-call g_main_loop_unref loop)
          (extern-call g_free ctx)
          0)))))))
