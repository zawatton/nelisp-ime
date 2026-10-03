;; GTK4 owns only presentation and event translation; all conversion is in the child.
(seq
 (data-blob title "NeLisp GTK4 IME\0" rodata)
 (data-blob sig_close "close-request\0" rodata)
 (data-blob sig_key "key-pressed\0" rodata)
 (data-blob sig_poll "timeout\0" rodata)
 (data-blob empty "\0" rodata)
 (data-blob ready "READY\0" rodata)
 (data-blob request_fmt "(native-ime-request \"%s\" \"%s\" %d)\n\0" rodata)
 (data-blob op_key "key\0" rodata)
 (data-blob op_backspace "backspace\0" rodata)
 (data-blob op_commit "commit\0" rodata)
 (data-blob op_select "select-candidate\0" rodata)
 (data-blob trace_ready "ENGINE_READY\n\0" rodata)
 (data-blob trace_pre "PREEDIT: %s\n\0" rodata)
 (data-blob trace_candidates "CANDIDATES: %s\n\0" rodata)
 (data-blob trace_commit "COMMIT: %s\n\0" rodata)
 (data-blob trace_error "ENGINE_ERROR: %s\n\0" rodata)
 (data-blob field_result "result\0" rodata)
 (data-blob field_preedit "preedit\0" rodata)
 (data-blob field_candidates "candidates\0" rodata)
 (data-blob field_commit "commit\0" rodata)
 (data-blob bootstrap "(load (getenv \"NELISP_IME_ENTRY\"))\n\0" rodata)
 (data-blob arg_repl "--repl\0" rodata)
 (data-blob arg_no_prompt "--no-prompt\0" rodata)
 (data-blob arg_no_print "--no-print\0" rodata)
 (data-blob stderr_format "ENGINE_STDERR: %s\n\0" rodata)
 (data-blob candidate_pair_fmt "%s / %s\0" rodata)
 (data-blob string_type_name "gchararray\0" rodata)
 (data-blob trace_pid "ENGINE_PID: %s\n\0" rodata)
 (data-blob env_runtime "NELISP_IME_RUNTIME\0" rodata)
 (data-blob env_entry "NELISP_IME_ENTRY\0" rodata)
 (data-blob env_response_ms "NELISP_IME_RESPONSE_TIMEOUT_MS\0" rodata)
 (data-blob env_startup_ms "NELISP_IME_STARTUP_TIMEOUT_MS\0" rodata)
 (data-blob msg_startup_timeout "startup timeout\0" rodata)
 (data-blob msg_response_timeout "response timeout\0" rodata)
 (data-blob msg_missing_env "missing NELISP_IME_RUNTIME/ENTRY\0" rodata)
 (data-blob msg_spawn_failed "spawn failed\0" rodata)
 (data-blob trace_queue_full "QUEUE_FULL\n\0" rodata)

 ;; Context pointers occupy 0..63; buffers/state follow at fixed offsets.
 (defun print-label (format label)
   (seq
    (extern-call g_print format (extern-call gtk_label_get_text label))
    0))

 (defun fail-engine (ctx message)
   (seq
    (ptr-write-u64 ctx 9312 2)
    (extern-call g_print (data-addr trace_error) message)
    (extern-call gtk_label_set_text (ptr-read-u64 ctx 32) (data-addr empty))
    (extern-call gtk_label_set_text (ptr-read-u64 ctx 40) (data-addr empty))
    (extern-call gtk_label_set_text (ptr-read-u64 ctx 48) (data-addr empty))
    (when (> (ptr-read-u64 ctx 8) 0)
      (extern-call g_subprocess_force_exit (ptr-read-u64 ctx 8)))
    (extern-call g_main_loop_quit (ptr-read-u64 ctx 0))
    0))

 (defun json-member-object (object key)
   (seq
    (let ((node (extern-call json_object_get_member object key)))
      (if (and node (= (extern-call json_node_get_node_type node) 0))
          (extern-call json_node_get_object node)
        -1))))

 (defun json-member-string (object key nullable)
   (seq
    (let ((node (extern-call json_object_get_member object key)))
      (if (and node
               (= (extern-call json_node_get_node_type node) 2)
               (= (extern-call g_strcmp0
                               (extern-call g_type_name
                                            (extern-call json_node_get_value_type node))
                               (data-addr string_type_name)) 0))
          (extern-call json_object_get_string_member object key)
        (if (and nullable node (= (extern-call json_node_get_node_type node) 3))
            0
          -1)))))

 (defun json-member-array (object key)
   (seq
    (let ((node (extern-call json_object_get_member object key)))
      (if (and node (= (extern-call json_node_get_node_type node) 1))
          (extern-call json_object_get_array_member object key)
        (if (and node (= (extern-call json_node_get_node_type node) 3))
            0
          -1)))))

 (defun render-candidates (ctx candidates line)
   (seq
   (let ((count (extern-call json_array_get_length candidates))
         (node 0)
         (value (data-addr empty)))
     (seq
      (ptr-write-u64 ctx 9336 count)
      (if (>= (ptr-read-u64 ctx 9320) count)
          (ptr-write-u64 ctx 9320 0)
        0)
      (if (= count 0)
          (extern-call gtk_label_set_text (ptr-read-u64 ctx 40) (data-addr empty))
        (seq
         (setq node (extern-call json_array_get_element
                                 candidates (ptr-read-u64 ctx 9320)))
         (if (and node
                  (= (extern-call json_node_get_node_type node) 2)
                  (= (extern-call g_strcmp0
                                  (extern-call g_type_name
                                               (extern-call json_node_get_value_type node))
                                  (data-addr string_type_name)) 0))
             (seq
              (setq value (extern-call json_array_get_string_element
                                       candidates (ptr-read-u64 ctx 9320)))
              (extern-call gtk_label_set_text (ptr-read-u64 ctx 40) value))
           (fail-engine ctx line))))
      (print-label (data-addr trace_candidates) (ptr-read-u64 ctx 40))
      0))
   0))

 (defun render-json (ctx parser line)
   (seq
    (let ((root 0) (object 0) (result 0) (preedit -1)
          (candidates -1) (commit -1))
      (seq
       (setq root (extern-call json_parser_get_root parser))
       (if (or (= root 0) (/= (extern-call json_node_get_node_type root) 0))
           (fail-engine ctx line)
         (seq
          (setq object (extern-call json_node_get_object root))
          (setq result (json-member-object object (data-addr field_result)))
          (if (< result 0)
              (fail-engine ctx line)
            (seq
             (setq preedit (json-member-string result (data-addr field_preedit) 0))
             (setq candidates (json-member-array result (data-addr field_candidates)))
             (setq commit (json-member-string result (data-addr field_commit) 1))
             (if (or (< preedit 0) (< candidates 0) (< commit 0))
                 (fail-engine ctx line)
               (seq
                (ptr-write-u64 ctx 9376 0)
                (extern-call gtk_label_set_text (ptr-read-u64 ctx 32) preedit)
                (print-label (data-addr trace_pre) (ptr-read-u64 ctx 32))
                (if (> candidates 0)
                    (render-candidates ctx candidates line)
                  (seq
                   (ptr-write-u64 ctx 9336 0)
                   (extern-call gtk_label_set_text (ptr-read-u64 ctx 40) (data-addr empty))
                   (print-label (data-addr trace_candidates) (ptr-read-u64 ctx 40))))
                (if (> commit 0)
                    (seq
                     (extern-call gtk_label_set_text (ptr-read-u64 ctx 48) commit)
                     (print-label (data-addr trace_commit) (ptr-read-u64 ctx 48)))
                  0)
                0))))
      0))
   0))))

 (defun render-response (ctx line)
   (seq
    (if (= (extern-call g_strcmp0 line (data-addr ready)) 0)
        (seq
         (ptr-write-u64 ctx 9312 1)
         (ptr-write-u64 ctx 9376 0)
         (ptr-write-u64 ctx 9288 0)
         (ptr-write-u64 ctx 9296 0)
         (extern-call g_print (data-addr trace_ready)))
      (let ((parser (extern-call json_parser_new)))
        (seq
         (if (= (extern-call json_parser_load_from_data parser line -1 0) 0)
             (fail-engine ctx (data-addr empty))
           (render-json ctx parser line))
         (extern-call g_object_unref parser)
         0)))))

 (defun queue-request (ctx operation key index)
   (seq
    (when (and (= (ptr-read-u64 ctx 9312) 1)
              (= (ptr-read-u64 ctx 9376) 0)
              (= (ptr-read-u64 ctx 9288) (ptr-read-u64 ctx 9296)))
     (let ((buffer (+ ctx 4160)))
       (seq
        (extern-call g_snprintf buffer 1024 (data-addr request_fmt)
                     operation key index)
        (ptr-write-u64 ctx 9288 (extern-call strlen buffer))
        (ptr-write-u64 ctx 9296 0)
        (ptr-write-u64 ctx 9376 1)
        (ptr-write-u64 ctx 9328 (+ (extern-call g_get_monotonic_time)
                                   (ptr-read-u64 ctx 9352))))))
    0))

 ;; Key kinds: 1 letter, 2 Backspace, 3 Enter, 4 Space.  Returns 1 when a
 ;; request was sent; Space without candidates sends nothing.
 (defun dispatch-key (ctx kind ch)
   (cond
    ((= kind 3)
     (seq (queue-request ctx (data-addr op_commit) (data-addr empty) 0) 1))
    ((= kind 2)
     (seq (queue-request ctx (data-addr op_backspace) (data-addr empty) 0) 1))
    ((= kind 4)
     (if (> (ptr-read-u64 ctx 9336) 0)
         (seq
          (ptr-write-u64 ctx 9320 (mod (+ (ptr-read-u64 ctx 9320) 1)
                                       (ptr-read-u64 ctx 9336)))
          (queue-request ctx (data-addr op_select) (data-addr empty)
                         (ptr-read-u64 ctx 9320))
          1)
       0))
    (t
     (seq
      (ptr-write-u64 ctx 9320 0)
      (ptr-write-u8 (+ ctx 10000) 0 ch)
      (ptr-write-u8 (+ ctx 10000) 1 0)
      (queue-request ctx (data-addr op_key) (+ ctx 10000) 0)
      1))))

 ;; Ring of 64 two-byte (kind, char) slots at 10016; head 9384, count 9392.
 (defun enqueue-key (ctx kind ch)
   (seq
    (if (< (ptr-read-u64 ctx 9392) 64)
        (let ((slot (+ ctx (+ 10016 (* 2 (mod (+ (ptr-read-u64 ctx 9384)
                                                  (ptr-read-u64 ctx 9392))
                                               64))))))
          (seq
           (ptr-write-u8 slot 0 kind)
           (ptr-write-u8 slot 1 ch)
           (ptr-write-u64 ctx 9392 (+ (ptr-read-u64 ctx 9392) 1))))
      (extern-call g_print (data-addr trace_queue_full)))
    1))

 ;; Send queued keys in order until one request is in flight.
 (defun drain-keys (ctx)
   (seq
    (while (and (= (ptr-read-u64 ctx 9312) 1)
                (= (ptr-read-u64 ctx 9376) 0)
                (> (ptr-read-u64 ctx 9392) 0))
      (let ((slot (+ ctx (+ 10016 (* 2 (ptr-read-u64 ctx 9384))))))
        (seq
         (ptr-write-u64 ctx 9384 (mod (+ (ptr-read-u64 ctx 9384) 1) 64))
         (ptr-write-u64 ctx 9392 (- (ptr-read-u64 ctx 9392) 1))
         (dispatch-key ctx (ptr-read-u8 slot 0) (ptr-read-u8 slot 1)))))
    0))

 (defun on_key (controller keyval keycode state ctx)
   (let ((kind 0) (ch 0))
     (seq
      (cond
       ((/= (logand state 469762060) 0) (setq kind 0))
       ((= keyval #xff0d) (setq kind 3))
       ((= keyval #xff08) (setq kind 2))
       ((= keyval 32) (setq kind 4))
       ((and (>= keyval 65) (<= keyval 90))
        (seq (setq kind 1) (setq ch (+ keyval 32))))
       ((and (>= keyval 97) (<= keyval 122))
        (seq (setq kind 1) (setq ch keyval)))
       (t (setq kind 0)))
      (cond
       ((= keyval #xff1b)
        (seq (extern-call g_main_loop_quit (ptr-read-u64 ctx 0)) 1))
       ((or (= kind 0) (/= (ptr-read-u64 ctx 9312) 1)) 0)
       ((or (= (ptr-read-u64 ctx 9376) 1) (> (ptr-read-u64 ctx 9392) 0))
        (enqueue-key ctx kind ch))
       (t (dispatch-key ctx kind ch))))))

 (defun on_close (window ctx)
   (seq (extern-call g_main_loop_quit (ptr-read-u64 ctx 0)) 1))

 (defun on_poll (ctx)
  (let ((now 0) (state 0) (buffer 0) (offset 0) (written 0)
        (read-buffer 0) (amount 0) (i 0) (out 0) (used 0) (byte 0)
        (err-buffer 0) (err-count 0))
    (seq
     (setq now (extern-call g_get_monotonic_time))
     (setq state (ptr-read-u64 ctx 9312))
     (when (and (= state 0) (> (- now (ptr-read-u64 ctx 9280))
                               (ptr-read-u64 ctx 9360)))
       (seq (fail-engine ctx (data-addr msg_startup_timeout)) 0))
     (when (and (= state 0) (= (ptr-read-u64 ctx 9288) 0))
       (seq
        (setq buffer (+ ctx 4160))
        (extern-call strcpy buffer (data-addr bootstrap))
        (ptr-write-u64 ctx 9288 (extern-call strlen buffer))
        (ptr-write-u64 ctx 9296 0)
        (ptr-write-u64 ctx 9376 1)
        (ptr-write-u64 ctx 9328 (+ (ptr-read-u64 ctx 9280)
                                   (ptr-read-u64 ctx 9360)))))
     (when (and (< state 2) (< (ptr-read-u64 ctx 9296) (ptr-read-u64 ctx 9288)))
       (seq
        (setq buffer (+ ctx 4160))
        (setq offset (ptr-read-u64 ctx 9296))
        (setq written (extern-call g_pollable_output_stream_write_nonblocking
                                   (ptr-read-u64 ctx 24) (+ buffer offset)
                                   (- (ptr-read-u64 ctx 9288) offset) 0 0))
        (when (> written 0)
          (ptr-write-u64 ctx 9296 (+ offset written)))))
     (when (and (= (ptr-read-u64 ctx 9376) 1)
                (> now (ptr-read-u64 ctx 9328)))
       (seq (fail-engine ctx (data-addr msg_response_timeout)) 0))
     (setq read-buffer (extern-call g_malloc 4096))
     (setq amount (extern-call g_pollable_input_stream_read_nonblocking
                               (ptr-read-u64 ctx 16) read-buffer 4096 0 0))
     (when (> amount 0)
       (seq
        (setq i 0)
        (setq out (+ ctx 64))
        (setq used (ptr-read-u64 ctx 9304))
        (while (and (< i amount) (< (ptr-read-u64 ctx 9312) 2))
          (seq
           (setq byte (ptr-read-u8 read-buffer i))
           (if (= byte 10)
               (seq
                (ptr-write-u8 out used 0)
                (render-response ctx out)
                (setq used 0)
                (ptr-write-u64 ctx 9304 0)
                (ptr-write-u64 ctx 9288 0)
                (ptr-write-u64 ctx 9296 0))
             (if (< used 4094)
                 (seq
                  (ptr-write-u8 out used byte)
                  (setq used (+ used 1))
                  (ptr-write-u64 ctx 9304 used))
               (fail-engine ctx (data-addr msg_response_timeout))))
           (setq i (+ i 1))))))
     (extern-call g_free read-buffer)
     (drain-keys ctx)
     (when (> (ptr-read-u64 ctx 9344) 0)
       (seq
        (setq err-buffer (extern-call g_malloc 1024))
        (setq err-count (extern-call g_pollable_input_stream_read_nonblocking
                                     (ptr-read-u64 ctx 9344) err-buffer 1023 0 0))
        (when (> err-count 0)
          (seq
           (ptr-write-u8 err-buffer err-count 0)
           (extern-call g_print (data-addr stderr_format) err-buffer)))
        (extern-call g_free err-buffer)))
     1)))

 (defun main ()
   (seq
    (extern-call gtk_init)
    (let ((ctx (extern-call g_malloc0 12000)))
      (seq
       (let ((window (extern-call gtk_window_new))
             (pre (extern-call gtk_label_new (data-addr empty)))
             (candidates (extern-call gtk_label_new (data-addr empty)))
             (commit (extern-call gtk_label_new (data-addr empty)))
             (box (extern-call gtk_box_new 1 8))
             (loop (extern-call g_main_loop_new 0 0))
             (keys (extern-call gtk_event_controller_key_new))
             (runtime (extern-call g_getenv (data-addr env_runtime)))
             (entry (extern-call g_getenv (data-addr env_entry)))
             (argv (extern-call g_malloc0 40))
             (response-ms (extern-call g_getenv (data-addr env_response_ms)))
             (startup-ms (extern-call g_getenv (data-addr env_startup_ms))))
         (if (or (= runtime 0) (= entry 0))
             (seq (extern-call g_print (data-addr trace_error) (data-addr msg_missing_env))
                  (extern-call g_free argv) (extern-call g_free ctx) 2)
           (seq
            (ptr-write-u64 argv 0 runtime)
            (ptr-write-u64 argv 8 (data-addr arg_repl))
            (ptr-write-u64 argv 16 (data-addr arg_no_prompt))
            (ptr-write-u64 argv 24 (data-addr arg_no_print))
            (ptr-write-u64 ctx 0 loop)
            (ptr-write-u64 ctx 32 pre)
            (ptr-write-u64 ctx 40 candidates)
            (ptr-write-u64 ctx 48 commit)
            (ptr-write-u64 ctx 9280 (extern-call g_get_monotonic_time))
            (let ((n (if response-ms (extern-call atoi response-ms) 500)))
              (ptr-write-u64 ctx 9352 (* (if (and (> n 0) (<= n 60000)) n 500) 1000)))
            (let ((n (if startup-ms (extern-call atoi startup-ms) 60000)))
              (ptr-write-u64 ctx 9360 (* (if (and (> n 0) (<= n 60000)) n 60000) 1000)))
            ;; STDIN_PIPE | STDOUT_PIPE | STDERR_PIPE.
            (let ((process (extern-call g_subprocess_newv argv 21 0)))
              (seq
              (extern-call g_free argv)
              (if (= process 0)
                  (seq (extern-call g_print (data-addr trace_error) (data-addr msg_spawn_failed))
                       (extern-call g_free ctx) 2)
                (seq
                 (ptr-write-u64 ctx 8 process)
                 (extern-call g_print (data-addr trace_pid)
                              (extern-call g_subprocess_get_identifier process))
                 (ptr-write-u64 ctx 16 (extern-call g_subprocess_get_stdout_pipe process))
                 (ptr-write-u64 ctx 24 (extern-call g_subprocess_get_stdin_pipe process))
                 (ptr-write-u64 ctx 9344 (extern-call g_subprocess_get_stderr_pipe process))
                 (extern-call gtk_window_set_title window (data-addr title))
                 (extern-call gtk_box_append box pre)
                 (extern-call gtk_box_append box candidates)
                 (extern-call gtk_box_append box commit)
                 (extern-call gtk_window_set_child window box)
                 (extern-call gtk_widget_add_controller window keys)
                 (extern-call g_signal_connect_data keys (data-addr sig_key) (addr-of on_key) ctx 0 0)
                 (extern-call g_signal_connect_data window (data-addr sig_close) (addr-of on_close) ctx 0 0)
                 (ptr-write-u64 ctx 56 (extern-call g_timeout_add 10 (addr-of on_poll) ctx))
                 (extern-call gtk_window_present window)
                 (extern-call g_main_loop_run loop)
                 (when (> (ptr-read-u64 ctx 56) 0)
                   (extern-call g_source_remove (ptr-read-u64 ctx 56)))
                 (extern-call g_subprocess_force_exit process)
                 (extern-call g_subprocess_wait process 0 0)
                 (extern-call g_object_unref process)
                 (extern-call gtk_window_destroy window)
                 (extern-call g_main_loop_unref loop)
                 (extern-call g_free ctx)
                 0))))))))))))
