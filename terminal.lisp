(uiop:define-package :lem-ghostty-terminal/terminal
  (:use :cl :lem)
  (:local-nicknames (:ffi :lem-ghostty-terminal/ffi)
                    (:line :lem/buffer/line))
  (:export :terminal
           :create
           :destroy
           :render
           :render-now
           :update
           :resize
           :scroll-viewport
           :scroll-to-bottom
           :scrolled-p
           :mouse-tracking-active-p
           :send-mouse-event
           :hyperlink-at
           :row-has-hyperlink-p
           :send-key
           :send-text
           :adjust-point
           :find-terminal-buffer
           :terminal-buffer
           :terminal-rows
           :terminal-cols
           :terminal-alive-p
           :terminal-copy-mode
           :copy-mode-on
           :copy-mode-off
           :ghostty-terminal-render-throttle-ms
           :ghostty-terminal-close-on-exit
           :ghostty-terminal-enable-osc52
           :ghostty-terminal-title-in-buffer-name
           :*terminal-term*))
(in-package :lem-ghostty-terminal/terminal)

;;; --- configuration ----------------------------------------------------

(define-editor-variable ghostty-terminal-render-throttle-ms 33
  "Minimum milliseconds between terminal renders.

Rendering is self-paced: the next render is scheduled only after the previous
one completes plus this interval, so a terminal that is producing output faster
than the editor can draw it cannot starve the command loop.  The final frame is
never lost, and an idle terminal stops ticking entirely.")

(define-editor-variable ghostty-terminal-close-on-exit t
  "Close the terminal buffer when its process exits.

With the default T, typing `exit' in the shell (or any other way of ending
the child process) removes the terminal buffer and gives its window back to
the previous buffer, the way a terminal emulator closes its window.  Set it
to NIL to keep the final screen visible; the buffer is then left read-only
and inert.

The last buffer in the editor is never deleted, because Lem needs at least
one buffer.")

(define-editor-variable ghostty-terminal-enable-osc52 nil
  "Allow programs to write the clipboard through OSC 52.

Off by default: a remote session can otherwise overwrite the local
clipboard without asking.  The bundled xterm-ghostty terminfo entry does
not advertise the `Ms' capability, so programs only use OSC 52 when this is
enabled and they try it explicitly.")

(define-editor-variable ghostty-terminal-title-in-buffer-name t
  "Rename the terminal buffer from the program's OSC 0/2 title.

When the program clears its title the buffer returns to `*Terminal*'.  A
manual rename stops the automatic tracking for that buffer.")

(defparameter *scrollback-max-bytes* (* 10 1024 1024)
  "Scrollback budget handed to libghostty-vt.  It is a page-granular
estimate: lowering it drops whole pages.")

(defparameter *read-buffer-size* 65536
  "Size of the octet buffer drained from the PTY in one read.")

(defparameter *write-buffer-size* 4096
  "Size of the foreign staging buffer used to write to the PTY.")

(defparameter *grapheme-buffer-size* 256
  "Bytes reserved for one cell's UTF-8 grapheme cluster.  256 is well past
the largest cluster libghostty-vt produces.")

(defparameter *attribute-cache-limit* 4096
  "Maximum entries in a terminal's attribute cache.  The cache is cleared
wholesale when it fills: that is cheaper than LRU bookkeeping on the render
hot path and it refills within a few frames.")

;; The errno values we care about.  EINTR is 4 everywhere we support, EIO is 5
;; on Linux and FreeBSD, and EAGAIN differs between Linux and the BSDs.
(defconstant +eintr+ 4)
(defconstant +eagain+ #+darwin 35 #-darwin 11)

;;; --- registry ---------------------------------------------------------

(defvar *terminal-id-counter* 0)
(defvar *terminals* '()
  "Live terminals, searched by id from the libghostty-vt callbacks.

`push' only changes the head, and callbacks run on the terminal's I/O thread,
so a plain list is enough.  Removal is done by the editor thread while the
terminal is being torn down.")

(defun next-terminal-id ()
  (incf *terminal-id-counter*))

(defun find-terminal-by-id (id)
  (find id *terminals* :key #'terminal-id))

(defun remove-terminal (terminal)
  (setf *terminals* (delete terminal *terminals*)))

(defun find-terminal-buffer ()
  "The buffer of the most recently created live terminal, if any."
  (alexandria:when-let ((terminal (first *terminals*)))
    (terminal-buffer terminal)))

;;; --- terminal object --------------------------------------------------

(defclass terminal ()
  ((id :initarg :id :reader terminal-id)
   (vt :initarg :vt :reader terminal-vt
       :documentation "GhosttyTerminal handle.")
   (render-state :initarg :render-state :reader terminal-render-state)
   (row-iterator :initarg :row-iterator :reader terminal-row-iterator)
   (row-cells :initarg :row-cells :reader terminal-row-cells)
   (key-encoder :initarg :key-encoder :reader terminal-key-encoder)
   (key-event :initarg :key-event :reader terminal-key-event)
   (process :initarg :process :reader terminal-process)
   (fd :initarg :fd :reader terminal-fd)
   (buffer :initarg :buffer :reader terminal-buffer)
   (rows :initarg :rows :accessor terminal-rows :type (integer 1 *))
   (cols :initarg :cols :accessor terminal-cols :type (integer 1 *))
   (title :initform nil :accessor terminal-title)
   (title-pending :initform nil :accessor terminal-title-pending)
   (managed-buffer-name :initform nil :accessor terminal-managed-buffer-name)
   (mouse-button-down :initform nil :accessor terminal-mouse-button-down)
   (mouse-last-cell :initform nil :accessor terminal-mouse-last-cell)
   (copy-mode :initform nil :accessor terminal-copy-mode :type boolean)
   (dead :initform nil :accessor terminal-dead :type boolean
         :documentation "The child process is gone; no more I/O or input.")
   (destroyed :initform nil :accessor terminal-destroyed :type boolean
              :documentation "DESTROY has freed the native objects.  Unlike
DEAD, this is a one-way latch, and only DESTROY sets it.")
   (exit-notified :initform nil :accessor terminal-exit-notified :type boolean
                  :documentation "Set once the process-exit close has been
scheduled, so the I/O thread and DESTROY cannot close the buffer twice.")
   (pending :initform t :accessor terminal-pending
            :documentation "Set by the I/O thread when VT data was written.
The render timer consumes it.")
   (size-changed :initform t :accessor terminal-size-changed)
   (lock :initform (bt2:make-lock :name "ghostty-terminal")
         :reader terminal-lock
         :documentation "Serializes every libghostty-vt call.  The parser is
not thread-safe: the I/O thread writes VT bytes while the editor thread
renders, resizes, scrolls, and encodes keys.")
   (render-lock :initform (bt2:make-lock :name "ghostty-terminal-render")
                :reader terminal-render-lock)
   (render-timer :initform nil :accessor terminal-render-timer)
   (render-timer-armed :initform nil :accessor terminal-render-timer-armed)
   (thread :initarg :thread :accessor terminal-thread)
   (attribute-cache :initform (make-hash-table :test #'eql)
                    :reader terminal-attribute-cache)
   ;; Foreign scratch objects reused on every frame and every keypress.
   (read-buffer :initarg :read-buffer :reader terminal-read-buffer)
   (write-buffer :initarg :write-buffer :reader terminal-write-buffer)
   (grapheme-buffer :initarg :grapheme-buffer :reader terminal-grapheme-buffer)
   (grapheme-struct :initarg :grapheme-struct :reader terminal-grapheme-struct)
   (style-struct :initarg :style-struct :reader terminal-style-struct)
   (cursor-struct :initarg :cursor-struct :reader terminal-cursor-struct)
   (colors-struct :initarg :colors-struct :reader terminal-colors-struct)
   (key-buffer :initarg :key-buffer :reader terminal-key-buffer)
   (key-string :initarg :key-string :reader terminal-key-string)
   (encode-buffer :initarg :encode-buffer :reader terminal-encode-buffer)))

(defun terminal-alive-p (terminal)
  (not (terminal-dead terminal)))

;;; --- PTY --------------------------------------------------------------

(defvar *setsid-command*
  :unknown
  "Memoized result of looking for setsid(1) with -c support: the program
name, NIL when unavailable, or :UNKNOWN before the first probe.")

(defun probe-setsid ()
  "Find setsid(1) and check that it supports -c/--ctty.
SBCL's :PTY support allocates a pty but does not make it the child's
controlling terminal, so the shell would start without job control.  Running
the child under `setsid -c' gives it a session and a controlling terminal
without a native helper."
  (or (loop :for dir :in (uiop:split-string (or (uiop:getenv "PATH") "")
                                            :separator ":" )
            :for path := (merge-pathnames "setsid" (uiop:ensure-directory-pathname dir))
            :when (probe-file path)
              :return (namestring path))
      nil))

(defun setsid-command ()
  (when (eq *setsid-command* :unknown)
    (setf *setsid-command*
          (let ((program (probe-setsid)))
            (when program
              (handler-case
                  (let ((help (uiop:run-program (list program "--help")
                                                :output :string
                                                :error-output :string
                                                :ignore-error-status t)))
                    (when (search "-c" help)
                      program))
                (error () nil))))))
  *setsid-command*)

(defparameter *terminal-term* (or (uiop:getenv "LEM_GHOSTTY_VT_TERM")
                                  "xterm-ghostty")
  "TERM value used for local terminal programs.

xterm-ghostty is backed by the terminfo entry bundled in this extension, so
programs can discover synchronized output, the Kitty keyboard protocol,
true colour and the other modern capabilities libghostty-vt implements.")

(defun terminal-terminfo-directory ()
  (asdf:system-relative-pathname :lem-ghostty-terminal "terminfo/"))

(defun terminal-environment (&key (term *terminal-term*))
  "The parent environment with TERM (and TERMINFO) set for the terminal."
  (let* ((terminfo (terminal-terminfo-directory))
         (bundled (uiop:directory-exists-p terminfo))
         ;; Do not advertise xterm-ghostty if a checkout is missing the
         ;; bundled terminfo directory; programs would fail to find it.
         (term (if (and (string= term "xterm-ghostty") (not bundled))
                   "xterm-256color"
                   term))
         (entries (remove-if (lambda (entry)
                               (or (eql 0 (search "TERM=" entry))
                                   (eql 0 (search "TERMINFO=" entry))))
                             (sb-ext:posix-environ))))
    (append (list (format nil "TERM=~A" term))
            (when (and bundled (string= term "xterm-ghostty"))
              (list (format nil "TERMINFO=~A" (namestring terminfo))))
            entries)))

(defun spawn-process (directory program argv &key (term *terminal-term*))
  "Start PROGRAM (default: $SHELL) under a fresh PTY, in DIRECTORY.
ARGV, when given, is the full argument vector including the program name,
matching the convention of `lem-terminal'; it is trimmed to the arguments
SBCL wants.  Returns the PROCESS."
  (let* ((shell (or (uiop:getenv "SHELL") "/bin/sh"))
         (program (or program shell))
         (arguments (cond ((null argv) nil)
                          ((equal (first argv) program) (rest argv))
                          (t argv)))
         (setsid (setsid-command))
         (environment (terminal-environment :term term)))
    (if setsid
        (sb-ext:run-program setsid
                            (append (list "-c" program) arguments)
                            :pty t
                            :wait nil
                            :search t
                            :directory directory
                            :environment environment)
        (sb-ext:run-program program
                            arguments
                            :pty t
                            :wait nil
                            :search t
                            :directory directory
                            :environment environment))))

(defun process-fd (process)
  "The master side of PROCESS's pty."
  (sb-sys:fd-stream-fd (sb-ext:process-pty process)))

;;; --- PTY window size ---------------------------------------------------

;; ioctl request to set struct winsize on the pty.  Linux uses a plain
;; _IOW('t', 103, struct winsize); the BSDs and macOS use the sized form.
(defconstant +tiocswinsz+
  #+linux #x5414
  #+(or darwin freebsd) #x80087467
  #-(or linux darwin freebsd) #x5414)

(cffi:defcfun ("ioctl" %ioctl) :int
  (fd :int)
  (request :unsigned-long)
  (arg :pointer))

(defun set-pty-window-size (terminal rows cols)
  "Tell the program in TERMINAL that its window is ROWS by COLS.

libghostty-vt only knows the grid size.  The child asks the kernel for its
window size separately, with TIOCGWINSZ on the pty slave, and programs use
that to lay out prompts and full-screen UIs.  The ioctl also makes the
kernel send SIGWINCH to the foreground process group, so full-screen
programs redraw at the new size."
  (cffi:with-foreign-object (winsize :uint16 4)
    ;; struct winsize { ws_row, ws_col, ws_xpixel, ws_ypixel; }
    (setf (cffi:mem-aref winsize :uint16 0) rows
          (cffi:mem-aref winsize :uint16 1) cols
          (cffi:mem-aref winsize :uint16 2) 0
          (cffi:mem-aref winsize :uint16 3) 0)
    (ignore-errors
      (%ioctl (terminal-fd terminal) +tiocswinsz+ winsize))))

;;; --- I/O thread -------------------------------------------------------

(defun write-to-pty (terminal pointer length)
  "Write LENGTH bytes at POINTER to the PTY, retrying short writes.
Callers must hold TERMINAL-LOCK (except the WRITE-PTY effect callback, which
already runs inside a locked VT write)."
  (let ((fd (terminal-fd terminal)))
    (loop :with offset := 0
          :while (< offset length)
          :do (multiple-value-bind (written errno)
                  (sb-unix:unix-write fd pointer offset (- length offset))
                (cond ((and written (plusp written))
                       (incf offset written))
                      ((eql errno +eintr+))
                      (t (return)))))))

(defun write-octets (terminal octets)
  (sb-sys:with-pinned-objects (octets)
    (write-to-pty terminal (sb-sys:vector-sap octets) (length octets))))

(defun handle-write-pty (id data len)
  "Effect callback: libghostty-vt produced reply bytes for the program."
  (alexandria:when-let ((terminal (find-terminal-by-id id)))
    (unless (terminal-dead terminal)
      (write-to-pty terminal data len))))

(defun handle-bell (id)
  "Effect callback: BEL.  Lem has no portable bell, so this is a no-op hook."
  (declare (ignore id)))

(defun handle-title (id)
  "Effect callback: mark the title for refresh on the editor thread.
Reading the title needs the terminal lock, which the I/O thread holds while
parsing, so the actual read happens during the next render."
  (alexandria:when-let ((terminal (find-terminal-by-id id)))
    (setf (terminal-title-pending terminal) t)
    (setf (terminal-pending terminal) t)
    (arm-render-timer terminal)))

(defun clipboard-text (contents)
  "Pick the first text representation from a clipboard CONTENTS alist."
  (alexandria:when-let ((entry
                          (find-if (lambda (entry)
                                     (and (stringp (car entry))
                                          (search "text/" (car entry)
                                                  :test #'char-equal)))
                                   contents)))
    (cdr entry)))

(defun handle-clipboard-write (id location contents)
  "Effect callback: OSC 52 / OSC 5522 clipboard write.
Runs on the I/O thread, so it queues the actual clipboard update on the
editor thread and answers the program immediately."
  (declare (ignore id location))
  (when (variable-value 'ghostty-terminal-enable-osc52 :global)
    (let ((text (or (clipboard-text contents) "")))
      (send-event (lambda ()
                    (ignore-errors (copy-to-clipboard text))))
      t)))

(defun close-terminal-buffer (terminal)
  "Delete TERMINAL's buffer after its process exited.
Runs on the editor thread.  Deleting the buffer switches every window that
shows it to another buffer and runs KILL-BUFFER-HOOK, which calls DESTROY."
  (let ((buffer (terminal-buffer terminal)))
    (when (and (variable-value 'ghostty-terminal-close-on-exit :global)
               (not (deleted-buffer-p buffer))
               ;; Lem must keep at least one buffer.
               (cdr (buffer-list)))
      (delete-buffer buffer))))

(defun notify-process-exit (terminal)
  "Schedule CLOSE-TERMINAL-BUFFER on the editor thread.
The I/O thread must not touch buffers or windows, so it only queues."
  (unless (terminal-exit-notified terminal)
    (setf (terminal-exit-notified terminal) t)
    (handler-case
        (send-event (lambda () (close-terminal-buffer terminal)))
      (error ()
        ;; No event queue (batch use / editor already gone): leave the
        ;; buffer alone rather than signalling from the I/O thread.
        nil))))

(defun mark-process-exited (terminal)
  "Record that the child is gone and ask the editor to close the buffer."
  (setf (terminal-dead terminal) t)
  (notify-process-exit terminal))

(defun io-loop (terminal)
  "Drain the PTY and feed the bytes to libghostty-vt forever."
  (let ((buffer (terminal-read-buffer terminal))
        (fd (terminal-fd terminal)))
    (loop
      (when (terminal-dead terminal)
        (return))
      (handler-case
          (when (sb-sys:wait-until-fd-usable fd :input 0.1)
            (multiple-value-bind (count errno)
                (sb-sys:with-pinned-objects (buffer)
                  (sb-unix:unix-read fd (sb-sys:vector-sap buffer) (length buffer)))
              (cond
                ((and count (plusp count))
                 (bt2:with-lock-held ((terminal-lock terminal))
                   (unless (terminal-dead terminal)
                     (ffi:terminal-write-vt
                      (terminal-vt terminal)
                      (sb-sys:vector-sap buffer)
                      count)))
                 (setf (terminal-pending terminal) t)
                 (arm-render-timer terminal))
                ((and count (zerop count))
                 (mark-process-exited terminal)
                 (return))
                ((member errno (list +eintr+ +eagain+)))
                (t
                 ;; EIO is what a pty returns once the child is gone.
                 (mark-process-exited terminal)
                 (return)))))
        (error ()
          (unless (terminal-dead terminal)
            (sleep 0.05)))))))

;;; --- render timer -----------------------------------------------------

(defun arm-render-timer (terminal)
  "Schedule a render tick if one is not already pending."
  (when (and (terminal-pending terminal)
             (not (terminal-dead terminal))
             (not (terminal-copy-mode terminal)))
    (let ((arm nil))
      (bt2:with-lock-held ((terminal-render-lock terminal))
        (unless (terminal-render-timer-armed terminal)
          (setf (terminal-render-timer-armed terminal) t
                arm t)))
      (when arm
        (let ((timer (or (terminal-render-timer terminal)
                         (setf (terminal-render-timer terminal)
                               (make-timer (lambda () (render-tick terminal))
                                           :name "ghostty-terminal-render")))))
          ;; START-TIMER needs the editor's timer manager.  In a headless
          ;; session (tests, batch use) there is none; rendering is then
          ;; driven by UPDATE or RENDER-NOW instead.
          (unless (handler-case
                      (progn
                        (start-timer timer
                                     (variable-value
                                      'ghostty-terminal-render-throttle-ms
                                      :global))
                        t)
                    (error () nil))
            (bt2:with-lock-held ((terminal-render-lock terminal))
              (setf (terminal-render-timer-armed terminal) nil))))))))

(defun render-tick (terminal)
  "Editor-thread render tick.  The timer manager redraws the display after
this returns."
  (bt2:with-lock-held ((terminal-render-lock terminal))
    (setf (terminal-render-timer-armed terminal) nil))
  (when (and (terminal-pending terminal)
             (not (terminal-dead terminal))
             (not (terminal-copy-mode terminal)))
    ;; Clear before rendering: output parsed during the render sets it again.
    (setf (terminal-pending terminal) nil)
    (bt2:with-lock-held ((terminal-lock terminal))
      (render terminal)))
  (arm-render-timer terminal))

(defun render-now (terminal)
  "Render synchronously on the calling (editor) thread.

The editor redraws after a command returns, so this does not call
REDRAW-DISPLAY itself; that keeps the function usable in batch sessions
and from the REPL."
  (bt2:with-lock-held ((terminal-lock terminal))
    (render terminal)))

;;; --- colors and attributes -------------------------------------------

(defvar *palette* nil
  "Foreign pointer to the 256-entry RGB palette of the frame being drawn.")

(defun palette-color (index)
  (let ((offset (* index 3)))
    (list (cffi:mem-aref *palette* :uint8 offset)
          (cffi:mem-aref *palette* :uint8 (+ offset 1))
          (cffi:mem-aref *palette* :uint8 (+ offset 2)))))

(defun color-code (tag r g b)
  "Pack a style color as 0 (default) or 1+RGB.  Palette entries are resolved
now so the cached attribute stays correct when a program changes the palette
later."
  (case tag
    (0 0)
    (1 (destructuring-bind (pr pg pb) (palette-color r)
         (+ 1 (logior (ash pr 16) (ash pg 8) pb))))
    (2 (+ 1 (logior (ash r 16) (ash g 8) b)))
    (t 0)))

(defun color-from-code (code)
  (when (plusp code)
    (let ((rgb (1- code)))
      (make-color (ldb (byte 8 16) rgb)
                  (ldb (byte 8 8) rgb)
                  (ldb (byte 8 0) rgb)))))

(defun decoration-code (flags)
  "The nine bits of visual style that survive in a cache key."
  (logior (if (logtest flags ffi:+style-bold+) 1 0)
          (if (logtest flags ffi:+style-italic+) 2 0)
          (if (logtest flags ffi:+style-faint+) 4 0)
          (if (logtest flags ffi:+style-inverse+) 8 0)
          (if (logtest flags ffi:+style-invisible+) 16 0)
          (if (logtest flags ffi:+style-strikethrough+) 32 0)
          (ash (ldb (byte 3 ffi:+style-underline-shift+) flags) 6)))

(defun style-key (style)
  "Pack a GhosttyStyle into one fixnum: fg 25 bits, bg 25 bits, deco 9 bits."
  (multiple-value-bind (fg-tag fg-r fg-g fg-b) (ffi:style-fg style)
    (multiple-value-bind (bg-tag bg-r bg-g bg-b) (ffi:style-bg style)
      (logior (color-code fg-tag fg-r fg-g fg-b)
              (ash (color-code bg-tag bg-r bg-g bg-b) 25)
              (ash (decoration-code (ffi:style-flags style)) 50)))))

(defun attribute-from-key (terminal key)
  (declare (ignore terminal))
  (let* ((deco (ldb (byte 9 50) key))
         (bg (ldb (byte 25 25) key))
         (fg (ldb (byte 25 0) key))
         (underline (ldb (byte 3 6) deco)))
    (make-attribute
     :foreground (color-from-code fg)
     :background (color-from-code bg)
     :bold (logbitp 0 deco)
     :italic (logbitp 1 deco)
     :dim (logbitp 2 deco)
     :reverse (logbitp 3 deco)
     :strikethrough (logbitp 5 deco)
     :underline (plusp underline)
     :underline-style (case underline
                        (1 :straight)
                        (2 :double)
                        (3 :curly)
                        (4 :dotted)
                        (5 :dashed)
                        (t nil)))))

(defun cached-attribute (terminal key)
  (let ((cache (terminal-attribute-cache terminal)))
    (or (gethash key cache)
        (progn
          (when (>= (hash-table-count cache) *attribute-cache-limit*)
            (clrhash cache))
          (setf (gethash key cache) (attribute-from-key terminal key))))))

(defun clear-attribute-cache (terminal)
  (clrhash (terminal-attribute-cache terminal)))

;;; --- UTF-8 ------------------------------------------------------------

(defun first-codepoint (pointer length)
  "Decode the first UTF-8 scalar value of POINTER."
  (let ((b0 (cffi:mem-aref pointer :uint8 0)))
    (cond ((< b0 #x80) b0)
          ((< length 2) #xFFFD)
          ((< b0 #xE0)
           (logior (ash (logand b0 #x1F) 6)
                   (logand (cffi:mem-aref pointer :uint8 1) #x3F)))
          ((< length 3) #xFFFD)
          ((< b0 #xF0)
           (logior (ash (logand b0 #x0F) 12)
                   (ash (logand (cffi:mem-aref pointer :uint8 1) #x3F) 6)
                   (logand (cffi:mem-aref pointer :uint8 2) #x3F)))
          ((< length 4) #xFFFD)
          (t
           (logior (ash (logand b0 #x07) 18)
                   (ash (logand (cffi:mem-aref pointer :uint8 1) #x3F) 12)
                   (ash (logand (cffi:mem-aref pointer :uint8 2) #x3F) 6)
                   (logand (cffi:mem-aref pointer :uint8 3) #x3F))))))

(defun cell-width (pointer length)
  "Display width of a cell, from the width of its base codepoint."
  (if (zerop length)
      1
      (let ((first (cffi:mem-aref pointer :uint8 0)))
        (if (< first #x80)
            1
            (max 1 (ffi:codepoint-width (first-codepoint pointer length)))))))

(defun append-graphemes (pointer length output)
  "Append POINTER's LENGTH UTF-8 bytes to the adjustable string OUTPUT."
  (if (and (= length 1) (< (cffi:mem-aref pointer :uint8 0) #x80))
      (vector-push-extend (code-char (cffi:mem-aref pointer :uint8 0)) output)
      (loop :for char :across (handler-case
                                  (cffi:foreign-string-to-lisp pointer
                                                               :count length
                                                               :encoding :utf-8)
                                (error ()
                                  ;; Invalid UTF-8: keep the layout stable.
                                  (make-string 1 :initial-element (code-char #xFFFD)))
                              )
            :do (vector-push-extend char output))))

;;; --- rendering --------------------------------------------------------

(defun ensure-buffer-lines (buffer rows)
  "Make BUFFER contain exactly ROWS lines."
  (let ((point (buffer-point buffer)))
    (let ((nlines (buffer-nlines buffer)))
      (cond ((< nlines rows)
             (buffer-end point)
             (dotimes (i (- rows nlines))
               (declare (ignore i))
               (insert-character point #\newline)))
            ((> nlines rows)
             (move-to-line point (1+ rows))
             (line-start point)
             (with-point ((start point))
               (character-offset start -1)
               (buffer-end point)
               (delete-between-points start point)))))))

(defun line-at (first-line index)
  (loop :with line := first-line
        :repeat index
        :do (setf line (line:line-next line))
        :finally (return line)))

(defun render-row (terminal iterator cells-container line)
  "Draw the row the row iterator currently points at into LINE."
  (ffi:row-get iterator ffi:+row-data-cells+ cells-container)
  (let ((cells (cffi:mem-ref cells-container :pointer))
        (style (terminal-style-struct terminal))
        (grapheme (terminal-grapheme-struct terminal))
        (grapheme-buffer (terminal-grapheme-buffer terminal))
        (output (make-array 32 :element-type 'character
                               :adjustable t :fill-pointer 0))
        (runs '())
        (run-start 0)
        (char-count 0)
        (last-key :none)
        (skip-next nil))
    (loop :while (ffi:row-cells-next cells)
          :do (if skip-next
                  (setf skip-next nil)
                  (progn
                    (ffi:row-cells-style cells style)
                    (let ((key (style-key style)))
                      (unless (eql key last-key)
                        (when (and last-key (not (eql last-key :none)))
                          (push (list run-start char-count
                                      (cached-attribute terminal last-key))
                                runs))
                        (setf run-start char-count
                              last-key key)))
                    (ffi:buffer-reset grapheme grapheme-buffer
                                      *grapheme-buffer-size*)
                    (ffi:row-cells-graphemes cells grapheme)
                    (let* ((len (ffi:buffer-len grapheme))
                           (invisible (logtest (ffi:style-flags style)
                                               ffi:+style-invisible+))
                           (width (cell-width grapheme-buffer len)))
                      (cond
                        ((or invisible (zerop len))
                         (dotimes (i width)
                           (declare (ignore i))
                           (vector-push-extend #\Space output))
                         (incf char-count width))
                        (t
                         (when (= width 2)
                           (setf skip-next t))
                         (append-graphemes grapheme-buffer len output)
                         (incf char-count)))))))
    (when (and last-key (not (eql last-key :none)))
      (push (list run-start char-count (cached-attribute terminal last-key))
            runs))
    (line:set-line-string (subseq output 0) line)
    (setf (getf (line:line-plist line) :attribute) (nreverse runs))
    (values)))

(defun update-cursor (terminal)
  "Move the buffer point to the terminal cursor."
  (let ((cursor (terminal-cursor-struct terminal)))
    (ffi:render-state-cursor (terminal-render-state terminal) cursor)
    (when (ffi:cursor-viewport-available-p cursor)
      (let ((x (ffi:cursor-x cursor))
            (y (ffi:cursor-y cursor)))
        (let ((point (buffer-point (terminal-buffer terminal))))
          (move-to-line point (1+ y))
          (move-to-column point x))))))

(defun sanitize-buffer-title (title)
  "Make TITLE usable as a Lem buffer name, or NIL when it is empty."
  (when title
    (let ((clean (map 'string
                      (lambda (char)
                        (if (or (< (char-code char) 32)
                                (= (char-code char) 127))
                            #\Space
                            char))
                      title)))
      (setf clean (string-trim '(#\Space #\Tab) clean))
      (when (plusp (length clean))
        (subseq clean 0 (min 80 (length clean)))))))

(defun apply-buffer-title (terminal title)
  "Rename TERMINAL's buffer from TITLE, unless the user renamed it."
  (let* ((buffer (terminal-buffer terminal))
         (managed (terminal-managed-buffer-name terminal))
         (current (buffer-name buffer)))
    (when (and managed (not (string= current managed)))
      ;; The user renamed it; stop managing the name.
      (setf managed nil)
      (setf (terminal-managed-buffer-name terminal) nil))
    (when managed
      (let* ((base (or (sanitize-buffer-title title) "*Terminal*"))
             (desired (if (string= base current)
                          current
                          (unique-buffer-name base))))
        (unless (string= desired current)
          (buffer-rename buffer desired)
          (setf (terminal-managed-buffer-name terminal) desired))))))

(defun update-buffer-title (terminal)
  "Consume a pending title change on the editor thread."
  (when (terminal-title-pending terminal)
    (setf (terminal-title-pending terminal) nil)
    (setf (terminal-title terminal)
          (ffi:terminal-title (terminal-vt terminal)))
    (when (variable-value 'ghostty-terminal-title-in-buffer-name :global)
      (apply-buffer-title terminal (terminal-title terminal)))))

(defun render (terminal)
  "Redraw the terminal buffer.
CONTRACT: the caller must hold TERMINAL-LOCK.  The render state is the only
libghostty-vt object touched here, and it is snapshotted by UPDATE while the
lock is held."
  (let* ((state (terminal-render-state terminal))
         (dirty (ffi:render-state-update state (terminal-vt terminal)))
         (force (or (terminal-size-changed terminal)
                    (eq dirty :full))))
    (when (or force (eq dirty :partial))
      (multiple-value-bind (cols rows) (ffi:render-state-size state)
        (setf (terminal-rows terminal) rows
              (terminal-cols terminal) cols
              (terminal-size-changed terminal) nil)
        (let ((buffer (terminal-buffer terminal))
              (colors (terminal-colors-struct terminal)))
          (ffi:render-state-colors state colors)
          (let ((*palette* (ffi:colors-palette colors)))
            (when force
              (clear-attribute-cache terminal))
            (with-buffer-read-only buffer nil
              (ensure-buffer-lines buffer rows)
              (buffer-start (buffer-point buffer))
              (let* ((first-line (point-line (buffer-point buffer)))
                     (iterator-container (terminal-row-iterator terminal))
                     (cells-container (terminal-row-cells terminal)))
                (ffi:render-state-get state ffi:+render-data-row-iterator+
                                      iterator-container)
                (let ((iterator (cffi:mem-ref iterator-container :pointer))
                      (rendered nil))
                  (cffi:with-foreign-object (y :uint16)
                    (loop :while (ffi:row-iterator-next-dirty iterator y)
                          :do (setf rendered t)
                              (render-row terminal iterator cells-container
                                          (line-at first-line
                                                   (cffi:mem-ref y :uint16))))
                    ;; next-dirty may yield nothing on a full redraw; walk
                    ;; every row in that case.
                    (when (and force (not rendered))
                      (loop :for row :from 0 :below rows
                            :while (ffi:row-iterator-next iterator)
                            :do (render-row terminal iterator cells-container
                                            (line-at first-line row))))))))))
        (ffi:render-state-clean state)))
    ;; Cursor-only movement marks no row dirty, but point must follow it.
    (update-cursor terminal)
    (update-buffer-title terminal)))

(defun adjust-point (terminal)
  "Move point to the terminal cursor, rendering first if needed."
  (bt2:with-lock-held ((terminal-lock terminal))
    (when (terminal-pending terminal)
      (setf (terminal-pending terminal) nil)
      (render terminal)))
  (update-cursor terminal))

(defun update (terminal)
  "Render synchronously without asking the frontend to redraw.  Useful in
tests and from the REPL; the interactive path uses the render timer."
  (setf (terminal-pending terminal) nil)
  (bt2:with-lock-held ((terminal-lock terminal))
    (render terminal)))

;;; --- size and scrolling ----------------------------------------------

(defun resize (terminal rows cols)
  "Resize the terminal grid to ROWS by COLS."
  (unless (and (= rows (terminal-rows terminal))
               (= cols (terminal-cols terminal)))
    (bt2:with-lock-held ((terminal-lock terminal))
      (setf (terminal-rows terminal) rows
            (terminal-cols terminal) cols
            (terminal-size-changed terminal) t)
      (ffi:terminal-resize (terminal-vt terminal) cols rows)
      (clear-attribute-cache terminal))
    (set-pty-window-size terminal rows cols)
    (setf (terminal-pending terminal) t)
    (arm-render-timer terminal)))

(defun scroll-viewport (terminal delta)
  "Scroll the viewport by DELTA rows (negative is up)."
  (bt2:with-lock-held ((terminal-lock terminal))
    (ffi:terminal-scroll-viewport (terminal-vt terminal)
                                  ffi:+scroll-delta+ (round delta))
    (setf (terminal-size-changed terminal) t)
    (setf (terminal-pending terminal) t))
  (render-now terminal))

(defun scroll-to-bottom (terminal)
  "Return the viewport to the active area."
  (bt2:with-lock-held ((terminal-lock terminal))
    (ffi:terminal-scroll-viewport (terminal-vt terminal)
                                  ffi:+scroll-bottom+ 0)
    (setf (terminal-size-changed terminal) t)
    (setf (terminal-pending terminal) t))
  (render-now terminal))

(defun scrolled-p (terminal)
  "True while the viewport shows scrollback instead of the active area."
  (bt2:with-lock-held ((terminal-lock terminal))
    (not (ffi:terminal-viewport-active-p (terminal-vt terminal)))))

;;; --- mouse ------------------------------------------------------------

(defun mouse-tracking-active-p (terminal)
  "True when the program has enabled any terminal mouse tracking mode."
  (bt2:with-lock-held ((terminal-lock terminal))
    (ffi:terminal-mouse-tracking-p (terminal-vt terminal))))

(defun mouse-button-index (button)
  (case button
    (:left 0)
    (:middle 1)
    (:right 2)
    (:wheel-up 64)
    (:wheel-down 65)
    (t 3)))

(defun mouse-tracking-mode (terminal)
  (let ((vt (terminal-vt terminal)))
    (cond ((ffi:terminal-mode-value vt 1003) :any)
          ((ffi:terminal-mode-value vt 1002) :button)
          ((ffi:terminal-mode-value vt 1000) :normal)
          ((ffi:terminal-mode-value vt 9) :x10)
          (t nil))))

(defun mouse-format (terminal)
  (let ((vt (terminal-vt terminal)))
    ;; SGR-pixels (1016) is rare; cell coordinates in SGR form keep the
    ;; protocol useful without tracking the font's pixel size.
    (cond ((ffi:terminal-mode-value vt 1016) :sgr)
          ((ffi:terminal-mode-value vt 1006) :sgr)
          ((ffi:terminal-mode-value vt 1015) :urxvt)
          ((ffi:terminal-mode-value vt 1005) :utf8)
          (t :x10))))

(defun encode-mouse-event (terminal action button x y format)
  "Return the bytes for a mouse event in FORMAT, or NIL."
  (declare (ignore terminal))
  (let* ((x (max 0 x))
         (y (max 0 y))
         (index (mouse-button-index button))
         (code (case action
                 (:release (if (eq format :x10) 3 index))
                 (:motion (+ 32 index))
                 (t index))))
    (ecase format
      (:x10
       (when (and (<= x 222) (<= y 222))
         (let ((string (make-string 6)))
           (setf (char string 0) #\Escape
                 (char string 1) #\[
                 (char string 2) #\M
                 (char string 3) (code-char (+ 32 code))
                 (char string 4) (code-char (+ 33 x))
                 (char string 5) (code-char (+ 33 y)))
           (sb-ext:string-to-octets string :external-format :utf-8))))
      (:utf8
       (let ((string (concatenate 'string
                                  (string #\Escape) "[M"
                                  (string (code-char (+ 32 code)))
                                  (string (code-char (+ 33 x)))
                                  (string (code-char (+ 33 y))))))
         (sb-ext:string-to-octets string :external-format :utf-8)))
      (:sgr
       (sb-ext:string-to-octets
        (format nil "~C[<~D;~D;~D~C"
                #\Escape code (1+ x) (1+ y)
                (if (eq action :release) #\m #\M))
        :external-format :utf-8))
      (:urxvt
       (sb-ext:string-to-octets
        (format nil "~C[~D;~D;~DM" #\Escape (+ 32 code) (1+ x) (1+ y))
        :external-format :utf-8)))))

(defun send-mouse-event (terminal action button x y)
  "Encode and send a mouse event to TERMINAL's program.
ACTION is :press, :release or :motion.  X and Y are viewport cell
coordinates.  Does nothing when mouse tracking is off or the event is not
part of the active tracking mode."
  (when (terminal-alive-p terminal)
    (bt2:with-lock-held ((terminal-lock terminal))
      (when (and (not (terminal-dead terminal))
                 (ffi:terminal-mouse-tracking-p (terminal-vt terminal)))
        (let* ((mode (mouse-tracking-mode terminal))
               (format (mouse-format terminal))
               (wheel (member button '(:wheel-up :wheel-down)))
               (report
                 (case mode
                   (:x10 (eq action :press))
                   (:normal (member action '(:press :release)))
                   (:button (or (member action '(:press :release))
                                (and (eq action :motion)
                                     (or (terminal-mouse-button-down terminal)
                                         button))))
                   (:any t)
                   (t nil))))
          (when (and report
                     (not (and (eq format :x10) (eq action :motion)))
                     (not (and (eq action :motion)
                               (equal (list x y)
                                      (terminal-mouse-last-cell terminal)))))
            (setf (terminal-mouse-last-cell terminal) (list x y))
            (when (and (not wheel) (eq action :press))
              (setf (terminal-mouse-button-down terminal) t))
            (when (and (not wheel) (eq action :release))
              (setf (terminal-mouse-button-down terminal) nil))
            (alexandria:when-let ((bytes
                                    (encode-mouse-event terminal action
                                                        button x y format)))
              (write-octets terminal bytes))))))))

;;; --- hyperlinks -------------------------------------------------------

(defun hyperlink-at (terminal row col)
  "Return the OSC 8 URI at viewport cell ROW, COL, or NIL."
  (bt2:with-lock-held ((terminal-lock terminal))
    (ffi:terminal-grid-ref-hyperlink-uri (terminal-vt terminal) col row)))

(defun row-has-hyperlink-p (terminal row)
  "True when viewport row ROW contains at least one OSC 8 hyperlink."
  (bt2:with-lock-held ((terminal-lock terminal))
    (ffi:terminal-row-has-hyperlink-p (terminal-vt terminal) row)))

;;; --- input ------------------------------------------------------------

(defun key-mods (key)
  (logior (if (key-ctrl key) ffi:+mod-ctrl+ 0)
          (if (key-meta key) ffi:+mod-alt+ 0)
          (if (key-shift key) ffi:+mod-shift+ 0)
          (if (key-super key) ffi:+mod-super+ 0)))

(defun key-text (key)
  "UTF-8 text for KEY, as libghostty-vt's encoder wants it: the character
the key produces before Ctrl/Alt are applied.  Named keys produce no text."
  (let ((sym (key-sym key)))
    (cond ((string= sym "Space") " ")
          ((= 1 (length sym))
           (if (< (char-code (char sym 0)) #x20) "" sym))
          (t ""))))

(defun key-code-for (key)
  (let ((sym (key-sym key)))
    (or (ffi:key-code sym)
        (when (= 1 (length sym))
          (ffi:key-code (string-downcase sym)))
        0)))

(defun encode-key (terminal key)
  "Encode KEY using libghostty-vt and return the bytes to write as a Lisp
octet vector, or NIL when the key produces no output."
  (let* ((text (key-text key))
         (octets (sb-ext:string-to-octets text :external-format :utf-8))
         (length (length octets))
         (utf8 (terminal-key-buffer terminal)))
    (when (> length *write-buffer-size*)
      (return-from encode-key nil))
    (loop :for byte :across octets
          :for i :from 0
          :do (setf (cffi:mem-aref utf8 :uint8 i) byte))
    (ffi:key-encoder-sync (terminal-key-encoder terminal) (terminal-vt terminal))
    (ffi:key-event-set (terminal-key-event terminal)
                       :action ffi:+key-action-press+
                       :key (key-code-for key)
                       :mods (key-mods key)
                       :utf8 (if (plusp length) utf8 nil)
                       :utf8-length length
                       :unshifted-codepoint (when (plusp length)
                                              (char-code (char text 0))))
    (let ((buffer (terminal-encode-buffer terminal)))
      (cffi:with-foreign-object (written :size)
        (let ((result (ffi:key-encoder-encode (terminal-key-encoder terminal)
                                              (terminal-key-event terminal)
                                              buffer 128 written)))
          (when (= result ffi:+result-success+)
            (let ((n (cffi:mem-ref written :size)))
              (when (plusp n)
                (let ((output (make-array n :element-type '(unsigned-byte 8))))
                  (dotimes (i n)
                    (setf (aref output i) (cffi:mem-aref buffer :uint8 i)))
                  output)))))))))

(defun send-key (terminal key)
  "Send one Lem KEY to the program."
  (when (terminal-copy-mode terminal)
    (copy-mode-off terminal))
  (when (scrolled-p terminal)
    (scroll-to-bottom terminal))
  (bt2:with-lock-held ((terminal-lock terminal))
    (unless (terminal-dead terminal)
      (alexandria:when-let ((bytes (encode-key terminal key)))
        (write-octets terminal bytes)))))

(defun send-text (terminal text)
  "Send TEXT to the program, honoring bracketed paste mode."
  (bt2:with-lock-held ((terminal-lock terminal))
    (unless (terminal-dead terminal)
      (let* ((bracketed
               (ffi:terminal-mode-value (terminal-vt terminal)
                                        ffi:+mode-bracketed-paste+))
             (payload (if bracketed
                          (concatenate 'string
                                       (string #\Escape) "[200~"
                                       text
                                       (string #\Escape) "[201~")
                          text)))
        (write-octets terminal
                      (sb-ext:string-to-octets payload :external-format :utf-8))))))

;;; --- copy mode --------------------------------------------------------

(defun copy-mode-on (terminal)
  (setf (terminal-copy-mode terminal) t))

(defun copy-mode-off (terminal)
  (setf (terminal-copy-mode terminal) nil)
  (setf (terminal-pending terminal) t)
  (arm-render-timer terminal))

;;; --- lifecycle --------------------------------------------------------

(defun make-terminal-object (&key id buffer rows cols process (term *terminal-term*))
  (let ((vt (ffi:terminal-new cols rows)))
    (handler-case
        (let* ((render-state (ffi:render-state-new))
               (iterator-container (cffi:foreign-alloc :pointer))
               (cells-container (cffi:foreign-alloc :pointer))
               (encoder (ffi:key-encoder-new))
               (event (ffi:key-event-new))
               (style (cffi:foreign-alloc '(:struct ffi::ghostty-style)))
               (cursor (cffi:foreign-alloc '(:struct ffi::ghostty-cursor)))
               (colors (cffi:foreign-alloc '(:struct ffi::ghostty-render-colors)))
               (grapheme (cffi:foreign-alloc '(:struct ffi::ghostty-buffer)))
               (grapheme-buffer (cffi:foreign-alloc :uint8
                                                    :count *grapheme-buffer-size*))
               (key-buffer (cffi:foreign-alloc :uint8 :count *write-buffer-size*))
               (encode-buffer (cffi:foreign-alloc :uint8 :count 128))
               (read-buffer (make-array *read-buffer-size*
                                        :element-type '(unsigned-byte 8))))
          (ffi:terminal-set vt ffi:+opt-userdata+ (cffi:make-pointer id))
          (ffi:terminal-set vt ffi:+opt-write-pty+
                            (cffi:callback ffi:cb-write-pty))
          (ffi:terminal-set vt ffi:+opt-bell+
                            (cffi:callback ffi:cb-bell))
          (ffi:terminal-set vt ffi:+opt-title-changed+
                            (cffi:callback ffi:cb-title))
          (ffi:terminal-set vt ffi:+opt-device-attributes+
                            (cffi:callback ffi:cb-device-attributes))
          (ffi:terminal-set vt ffi:+opt-clipboard-write+
                            (cffi:callback ffi:cb-clipboard-write))
          (ffi:terminal-set-terminfo-name vt term)
          (setf (cffi:mem-ref iterator-container :pointer)
                (ffi:row-iterator-new)
                (cffi:mem-ref cells-container :pointer)
                (ffi:row-cells-new))
          (set-terminal-scrollback-limit vt *scrollback-max-bytes*)
          (make-instance 'terminal
                         :id id
                         :vt vt
                         :render-state render-state
                         :row-iterator iterator-container
                         :row-cells cells-container
                         :key-encoder encoder
                         :key-event event
                         :process process
                         :fd (process-fd process)
                         :buffer buffer
                         :rows rows
                         :cols cols
                         :style-struct style
                         :cursor-struct cursor
                         :colors-struct colors
                         :grapheme-struct grapheme
                         :grapheme-buffer grapheme-buffer
                         :key-buffer key-buffer
                         :encode-buffer encode-buffer
                         :read-buffer read-buffer))
      (error (condition)
        (ffi:terminal-free vt)
        (error condition)))))

(defun set-terminal-scrollback-limit (vt bytes)
  (cffi:with-foreign-object (value :size)
    (setf (cffi:mem-ref value :size) bytes)
    (ffi:terminal-set vt ffi:+opt-scrollback-max-bytes+ value)))

(defun create (&key rows cols buffer directory (program nil) (argv nil)
                 (term *terminal-term*))
  "Create a terminal running PROGRAM (default: the user's shell) in
DIRECTORY and display it in BUFFER.  ROWS and COLS are the initial grid."
  (unless (ffi:load-library)
    (editor-error "libghostty-vt is not installed: build or install it and set LEM_GHOSTTY_VT_LIBRARY"))
  (let* ((process (spawn-process directory program argv :term term))
         (id (next-terminal-id))
         (terminal (make-terminal-object :id id :buffer buffer
                                         :rows rows :cols cols
                                         :term term
                                         :process process)))
    ;; The pty starts with no usable winsize; a program that asks before the
    ;; first editor resize would otherwise assume 80x24.
    (set-pty-window-size terminal rows cols)
    (setf (terminal-managed-buffer-name terminal) (buffer-name buffer))
    (push terminal *terminals*)
    (setf (terminal-thread terminal)
          (bt2:make-thread
           (lambda () (io-loop terminal))
           :name (format nil "Ghostty terminal ~D" id)))
    (setf (terminal-pending terminal) t)
    (arm-render-timer terminal)
    terminal))

(defun destroy (terminal)
  "Stop the terminal, kill its process, and free the native objects.

DEAD only means the child has exited; DESTROY still has to run to release
the VT, PTY and scratch buffers.  The two flags are separate so an `exit'
in the shell can trigger the close without leaking the native state."
  (unless (terminal-destroyed terminal)
    (bt2:with-lock-held ((terminal-lock terminal))
      (setf (terminal-destroyed terminal) t
            (terminal-dead terminal) t
            (terminal-exit-notified terminal) t))
    (alexandria:when-let ((timer (terminal-render-timer terminal)))
      (ignore-errors (stop-timer timer)))
    (ignore-errors (sb-ext:process-kill (terminal-process terminal) 15))
    (ignore-errors (sb-ext:process-close (terminal-process terminal)))
    (let ((thread (terminal-thread terminal)))
      (when (and thread (bt2:thread-alive-p thread))
        (ignore-errors (bt2:join-thread thread :timeout 1))
        (when (bt2:thread-alive-p thread)
          (ignore-errors (bt2:destroy-thread thread)))))
    (remove-terminal terminal)
    (ffi:render-state-free (terminal-render-state terminal))
    (ffi:row-iterator-free
     (cffi:mem-ref (terminal-row-iterator terminal) :pointer))
    (ffi:row-cells-free
     (cffi:mem-ref (terminal-row-cells terminal) :pointer))
    (cffi:foreign-free (terminal-row-iterator terminal))
    (cffi:foreign-free (terminal-row-cells terminal))
    (ffi:key-encoder-free (terminal-key-encoder terminal))
    (ffi:key-event-free (terminal-key-event terminal))
    (ffi:terminal-free (terminal-vt terminal))
    ;; The scratch structs are small; freeing them here keeps the package
    ;; correct if a future version creates and destroys many terminals.
    (cffi:foreign-free (terminal-style-struct terminal))
    (cffi:foreign-free (terminal-cursor-struct terminal))
    (cffi:foreign-free (terminal-colors-struct terminal))
    (cffi:foreign-free (terminal-grapheme-struct terminal))
    (cffi:foreign-free (terminal-grapheme-buffer terminal))
    (cffi:foreign-free (terminal-key-buffer terminal))
    (cffi:foreign-free (terminal-encode-buffer terminal))))

;;; --- effect wiring ----------------------------------------------------
;;;
;;; libghostty-vt calls these back for replies it generated (DSR, DA,
;;; XTGETTCAP, ...).  The ffi layer owns the C dispatchers because they
;;; must exist before any terminal is created.

(ffi:set-write-pty-function 'handle-write-pty)
(ffi:set-bell-function 'handle-bell)
(ffi:set-title-function 'handle-title)
(ffi:set-clipboard-write-function 'handle-clipboard-write)
