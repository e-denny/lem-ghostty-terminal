(uiop:define-package :lem-ghostty-terminal/ffi
  (:use :cl)
  (:export ;; lifecycle / library
           :library-available-p
           :load-library
           :*library-path*
           ;; terminal
           :terminal-new
           :terminal-free
           :terminal-resize
           :terminal-write-vt
           :terminal-set
           :terminal-get
           :terminal-scroll-viewport
           :terminal-title
           :terminal-mode-value
           :terminal-cols
           :terminal-rows
           :terminal-scrollback-rows
           :terminal-total-rows
           :terminal-viewport-active-p
           :terminal-mouse-tracking-p
           :terminal-grid-ref-hyperlink-uri
           :terminal-row-has-hyperlink-p
           :terminal-set-terminfo-name
           ;; mouse
           :mouse-encoder-new
           :mouse-encoder-free
           :mouse-encoder-set-size
           :mouse-encoder-sync
           :mouse-encoder-encode
           :mouse-event-new
           :mouse-event-free
           :mouse-event-set-press
           :mouse-event-set-release
           :mouse-event-set-motion
           :mouse-event-clear-button
           :mouse-event-set-position
           :+mouse-button-left+
           :+mouse-button-right+
           :+mouse-button-middle+
           :+mouse-button-four+
           :+mouse-button-five+
           ;; render state
           :render-state-new
           :render-state-free
           :render-state-update
           :render-state-get
           :render-state-clean
           :row-iterator-new
           :row-iterator-free
           :row-iterator-next
           :row-iterator-next-dirty
           :row-get
           :row-cells-new
           :row-cells-free
           :row-cells-next
           :row-cells-style
           :row-cells-graphemes
           :row-cells-foreground
           :row-cells-background
           :row-cells-selected-p
           ;; render state queries
           :render-state-size
           :render-state-cursor
           :render-state-colors
           ;; key encoding
           :key-encoder-new
           :key-encoder-free
           :key-encoder-sync
           :key-encoder-encode
           :key-event-new
           :key-event-free
           :key-event-set
           :key-code
           ;; unicode
           :codepoint-width
           ;; effect callbacks
           :style-fg
           :style-bg
           :style-flags
           :buffer-reset
           :buffer-len
           :cursor-viewport-available-p
           :cursor-x
           :cursor-y
           :colors-palette
           :set-write-pty-function
           :set-bell-function
           :set-title-function
           :set-clipboard-write-function
           :cb-write-pty
           :cb-bell
           :cb-title
           :cb-clipboard-write
           :cb-device-attributes
           ;; constants used by the terminal layer
           :+result-success+
           :+result-no-value+
           :+opt-userdata+
           :+opt-write-pty+
           :+opt-bell+
           :+opt-title-changed+
           :+opt-device-attributes+
           :+opt-scrollback-max-bytes+
           :+opt-scrollback-max-lines+
           :+opt-clipboard-write+
           :+opt-terminfo-name+
           :+term-data-cols+
           :+term-data-rows+
           :+term-data-title+
           :+term-data-mouse-tracking+
           :+term-data-total-rows+
           :+term-data-scrollback-rows+
           :+term-data-viewport-active+
           :+term-data-mode+
           :+render-data-cols+
           :+render-data-rows+
           :+render-data-dirty+
           :+render-data-row-iterator+
           :+render-data-cursor+
           :+render-data-colors+
           :+row-data-cells+
           :+cells-data-style+
           :+cells-data-graphemes-len+
           :+cells-data-graphemes+
           :+cells-data-graphemes-utf8+
           :+cells-data-fg+
           :+cells-data-bg+
           :+cells-data-selected+
           :+dirty-false+
           :+dirty-partial+
           :+dirty-full+
           :+scroll-top+
           :+scroll-bottom+
           :+scroll-delta+
           :+scroll-row+
           :+key-action-press+
           :+mod-shift+
           :+mod-ctrl+
           :+mod-alt+
           :+mod-super+
           :+mode-bracketed-paste+
           :+style-bold+
           :+style-italic+
           :+style-faint+
           :+style-blink+
           :+style-inverse+
           :+style-invisible+
           :+style-strikethrough+
           :+style-overline+
           :+style-underline-shift+
           :+style-underline-mask+))
(in-package :lem-ghostty-terminal/ffi)

;;; --- native library ---------------------------------------------------
;;;
;;; libghostty-vt is a standalone C library (no PTY, no renderer, no
;;; fonts): it parses VT bytes and exposes terminal state, including a
;;; render state that is cheap to walk.  Lem supplies the PTY (SBCL's
;;; :PTY support) and draws the cells itself, which is why there is no
;;; native shim in this extension.
;;;
;;; We look for the shared library in this order:
;;;   1. $LEM_GHOSTTY_VT_LIBRARY (a path or a linker-style name),
;;;   2. the copy vendored next to this file under lib/<os>/<arch>/,
;;;   3. the system loader path.

(defvar *library-path* nil
  "The path libghostty-vt was loaded from, or NIL when unavailable.")

(defvar *library-loaded-p* nil)

(defun native-library-directory ()
  "Directory holding a libghostty-vt build vendored with this extension."
  (asdf:system-relative-pathname
   :lem-ghostty-terminal
   (format nil "~(lib/~A/~A/~)" (uiop:operating-system) (uiop:architecture))))

(defun library-filenames ()
  "Candidate file names for the host platform, most specific first."
  (let ((dir (native-library-directory)))
    (list (uiop:getenv "LEM_GHOSTTY_VT_LIBRARY")
          (merge-pathnames "libghostty-vt.so.1" dir)
          (merge-pathnames "libghostty-vt.so" dir)
          (merge-pathnames "libghostty-vt.1.dylib" dir)
          (merge-pathnames "libghostty-vt.dylib" dir)
          (merge-pathnames "ghostty-vt.dll" dir)
          "libghostty-vt.so.1"
          "libghostty-vt.so"
          "libghostty-vt.1.dylib"
          "libghostty-vt.dylib"
          "ghostty-vt.dll")))

(defun load-library (&optional force)
  "Load libghostty-vt if it is not loaded yet.
Returns the loaded path, or NIL when no candidate could be loaded.  A
second call after success is a no-op unless FORCE is true."
  (when (or force (not *library-loaded-p*))
    (setf *library-loaded-p* nil
          *library-path* nil)
    (dolist (candidate (library-filenames))
      (when (and candidate (not (equal candidate "")))
        (let ((path (handler-case
                        (cffi:load-foreign-library candidate)
                      (error () nil))))
          (when path
            (setf *library-loaded-p* t
                  *library-path* path)
            (return))))))
  *library-path*)

(defun library-available-p ()
  "True when libghostty-vt can be loaded."
  (and (or *library-loaded-p* (load-library)) t))

;; Do not load the native library while the system is loaded.  Lem builds
;; dump an image after loading the extension, and a foreign library opened
;; in the build process cannot be relied on to survive `save-lisp-and-die'.
;; LOAD-LIBRARY runs from CREATE instead, in the live process.


;;; --- basic types and constants ---------------------------------------

(defconstant +result-success+ 0)
(defconstant +result-invalid-value+ -1)
(defconstant +result-no-value+ -4)
(defconstant +result-out-of-space+ -3)

;; GhosttyTerminalOption
(defconstant +opt-userdata+ 1)
(defconstant +opt-write-pty+ 2)
(defconstant +opt-bell+ 3)
(defconstant +opt-title-changed+ 6)
(defconstant +opt-device-attributes+ 9)
(defconstant +opt-scrollback-max-bytes+ 28)
(defconstant +opt-scrollback-max-lines+ 29)
(defconstant +opt-clipboard-write+ 27)
(defconstant +opt-terminfo-name+ 38)

;; GhosttyTerminalData
(defconstant +term-data-cols+ 1)
(defconstant +term-data-rows+ 2)
(defconstant +term-data-title+ 12)
(defconstant +term-data-mouse-tracking+ 11)
(defconstant +term-data-total-rows+ 14)
(defconstant +term-data-scrollback-rows+ 15)
(defconstant +term-data-viewport-active+ 32)
(defconstant +term-data-mode+ 37)

;; GhosttyRenderStateData
(defconstant +render-data-cols+ 1)
(defconstant +render-data-rows+ 2)
(defconstant +render-data-dirty+ 3)
(defconstant +render-data-row-iterator+ 4)
(defconstant +render-data-cursor+ 18)
(defconstant +render-data-colors+ 19)

;; GhosttyRenderStateRowData
(defconstant +row-data-cells+ 3)
(defconstant +row-data-viewport-y+ 6)

;; Mouse
(defconstant +mouse-action-press+ 0)
(defconstant +mouse-action-release+ 1)
(defconstant +mouse-action-motion+ 2)
(defconstant +mouse-button-left+ 1)
(defconstant +mouse-button-right+ 2)
(defconstant +mouse-button-middle+ 3)
(defconstant +mouse-button-four+ 4)
(defconstant +mouse-button-five+ 5)
(defconstant +mouse-encoder-opt-size+ 3)
(defconstant +mouse-encoder-opt-track-last-cell+ 5)

;; GhosttyPointTag
(defconstant +point-tag-viewport+ 1)

;; GhosttyClipboardWriteResult
(defconstant +clipboard-write-success+ 0)
(defconstant +clipboard-write-unsupported+ 2)

;; GhosttyRenderStateRowCellsData
(defconstant +cells-data-style+ 2)
(defconstant +cells-data-graphemes-len+ 3)
(defconstant +cells-data-graphemes+ 4)
(defconstant +cells-data-fg+ 6)
(defconstant +cells-data-bg+ 5)
(defconstant +cells-data-selected+ 7)
(defconstant +cells-data-graphemes-utf8+ 9)

;; GhosttyRenderStateDirty
(defconstant +dirty-false+ 0)
(defconstant +dirty-partial+ 1)
(defconstant +dirty-full+ 2)

;; GhosttyTerminalScrollViewportTag
(defconstant +scroll-top+ 0)
(defconstant +scroll-bottom+ 1)
(defconstant +scroll-delta+ 2)
(defconstant +scroll-row+ 3)

;; GhosttyKeyAction
(defconstant +key-action-press+ 1)

;; GhosttyMods
(defconstant +mod-shift+ 1)
(defconstant +mod-ctrl+ 2)
(defconstant +mod-alt+ 4)
(defconstant +mod-super+ 8)

;; GhosttyMode for bracketed paste, built the way ghostty_mode_new(2004,false) does.
(defconstant +mode-bracketed-paste+ 2004)

;; GhosttyStyleFlags
(defconstant +style-bold+ (ash 1 0))
(defconstant +style-italic+ (ash 1 1))
(defconstant +style-faint+ (ash 1 2))
(defconstant +style-blink+ (ash 1 3))
(defconstant +style-inverse+ (ash 1 4))
(defconstant +style-invisible+ (ash 1 5))
(defconstant +style-strikethrough+ (ash 1 6))
(defconstant +style-overline+ (ash 1 7))
(defconstant +style-underline-shift+ 8)
(defconstant +style-underline-mask+ (ash #x7 +style-underline-shift+))

;;; --- key codes --------------------------------------------------------
;;;
;;; GhosttyKey values are stable in the C ABI.  Keeping the table here
;;; avoids exporting ninety defconstants while still letting the mode
;;; layer talk about keys by their Lem name.

(defparameter *key-codes*
  '(("a" . 20) ("b" . 21) ("c" . 22) ("d" . 23) ("e" . 24) ("f" . 25)
    ("g" . 26) ("h" . 27) ("i" . 28) ("j" . 29) ("k" . 30) ("l" . 31)
    ("m" . 32) ("n" . 33) ("o" . 34) ("p" . 35) ("q" . 36) ("r" . 37)
    ("s" . 38) ("t" . 39) ("u" . 40) ("v" . 41) ("w" . 42) ("x" . 43)
    ("y" . 44) ("z" . 45)
    ("0" . 6) ("1" . 7) ("2" . 8) ("3" . 9) ("4" . 10)
    ("5" . 11) ("6" . 12) ("7" . 13) ("8" . 14) ("9" . 15)
    ("`" . 1) ("\\" . 2) ("[" . 3) ("]" . 4) ("," . 5) ("=" . 16)
    ("-" . 46) ("." . 47) ("'" . 48) (";" . 49) ("/" . 50)
    ("Space" . 63) ("Tab" . 64) ("Return" . 58) ("Backspace" . 53)
    ("Escape" . 120) ("Insert" . 72) ("Delete" . 68)
    ("Home" . 71) ("End" . 69)
    ("PageUp" . 74) ("PageDown" . 73)
    ("Up" . 78) ("Down" . 75) ("Left" . 76) ("Right" . 77)
    ("ContextMenu" . 55)
    ("F1" . 121) ("F2" . 122) ("F3" . 123) ("F4" . 124)
    ("F5" . 125) ("F6" . 126) ("F7" . 127) ("F8" . 128)
    ("F9" . 129) ("F10" . 130) ("F11" . 131) ("F12" . 132)
    ("F13" . 133) ("F14" . 134) ("F15" . 135) ("F16" . 136)
    ("F17" . 137) ("F18" . 138) ("F19" . 139) ("F20" . 140)
    ("F21" . 141) ("F22" . 142) ("F23" . 143) ("F24" . 144))
  "Lem key name -> GhosttyKey.  Single-character syms are looked up here
first; anything else becomes GHOSTTY_KEY_UNIDENTIFIED and is sent as text.")


;;; --- structs ----------------------------------------------------------

;; GhosttyStyleColor is { uint8 tag; union { uint8 palette; GhosttyColorRgb rgb; } }
;; so the union's first byte is the palette index and, for RGB, the red
;; component.  Flattening the three colors keeps render access to two
;; memory reads instead of walking nested structs.
(cffi:defcstruct ghostty-style
  (fg-tag :uint8) (fg-r :uint8) (fg-g :uint8) (fg-b :uint8)
  (bg-tag :uint8) (bg-r :uint8) (bg-g :uint8) (bg-b :uint8)
  (ul-tag :uint8) (ul-r :uint8) (ul-g :uint8) (ul-b :uint8)
  (flags :uint16)
  (reserved :uint16))

(cffi:defcstruct ghostty-string
  (ptr :pointer)
  (len :size))

(cffi:defcstruct ghostty-buffer
  (ptr :pointer)
  (cap :size)
  (len :size))

(cffi:defcstruct ghostty-render-colors
  (size :size)
  (bg-r :uint8) (bg-g :uint8) (bg-b :uint8)
  (fg-r :uint8) (fg-g :uint8) (fg-b :uint8)
  (cursor-r :uint8) (cursor-g :uint8) (cursor-b :uint8)
  (cursor-has-value :uint8)
  (palette :uint8 :count 768))

(cffi:defcstruct ghostty-cursor
  (size :size)
  (viewport-has-value :uint8)
  (viewport-x :uint16)
  (viewport-y :uint16)
  (wide-tail :uint8)
  (visible :uint8)
  (blinking :uint8)
  (password-input :uint8)
  (visual-style :int))

;; A tagged union: int tag, padding to pointer alignment, then a 16-byte
;; union whose first member is the intptr_t delta.  Keeping the trailing
;; padding makes the struct exactly sizeof(GhosttyTerminalScrollViewport).
(cffi:defcstruct ghostty-scroll-viewport
  (tag :int)
  (padding :int)
  (delta :intptr)
  (union-padding :uint64))

(cffi:defcstruct ghostty-mode-config
  (mode :uint16)
  (value :uint8)
  (padding :uint8))

;; GhosttyPoint: tag int, padding to 8, then a 16-byte union whose first
;; member is { uint16 x; uint32 y; } with its own trailing padding.
(cffi:defcstruct ghostty-point
  (tag :int)
  (padding :int)
  (x :uint16)
  (y-padding :uint16)
  (y :uint32)
  (union-padding :uint64))

(cffi:defcstruct ghostty-grid-ref
  (node :pointer)
  (x :uint16)
  (y :uint16))

(cffi:defcstruct ghostty-mouse-position
  (x :float)
  (y :float))

(cffi:defcstruct ghostty-mouse-encoder-size
  (size :size)
  (screen-width :uint32)
  (screen-height :uint32)
  (cell-width :uint32)
  (cell-height :uint32)
  (padding-top :uint32)
  (padding-bottom :uint32)
  (padding-right :uint32)
  (padding-left :uint32))

(cffi:defcstruct ghostty-clipboard-content
  (mime (:struct ghostty-string))
  (data (:struct ghostty-string)))

(cffi:defcstruct ghostty-clipboard-write
  (location :int)
  (contents :pointer)
  (contents-len :size)
  (name (:struct ghostty-string))
  (granted :boolean)
  (can-remember :boolean)
  (ctx :pointer)
  (reply :pointer))

(cffi:defcstruct ghostty-clipboard-write-reply
  (size :size)
  (result :int)
  (remember :boolean))

;;; --- terminal ---------------------------------------------------------

(cffi:defcfun ("ghostty_terminal_new" %terminal-new) :int
  (allocator :pointer)
  (out (:pointer :pointer))
  (cols :uint16)
  (rows :uint16))

(cffi:defcfun ("ghostty_terminal_free" %terminal-free) :void
  (terminal :pointer))

(cffi:defcfun ("ghostty_terminal_resize" %terminal-resize) :int
  (terminal :pointer)
  (cols :uint16)
  (rows :uint16)
  (cell-width :uint32)
  (cell-height :uint32))

(cffi:defcfun ("ghostty_terminal_vt_write" %terminal-vt-write) :void
  (terminal :pointer)
  (data :pointer)
  (len :size))

(cffi:defcfun ("ghostty_terminal_set" %terminal-set) :int
  (terminal :pointer)
  (option :int)
  (value :pointer))

(cffi:defcfun ("ghostty_terminal_get" %terminal-get) :int
  (terminal :pointer)
  (data :int)
  (out :pointer))

(cffi:defcfun ("ghostty_terminal_scroll_viewport" %terminal-scroll-viewport) :int
  (terminal :pointer)
  (behavior (:struct ghostty-scroll-viewport)))

(cffi:defcfun ("ghostty_terminal_grid_ref" %terminal-grid-ref) :int
  (terminal :pointer)
  (point (:struct ghostty-point))
  (out-ref :pointer))

(cffi:defcfun ("ghostty_grid_ref_row" %grid-ref-row) :int
  (ref :pointer)
  (out-row :pointer))

(cffi:defcfun ("ghostty_row_get" %row-data-get) :int
  (row :uint64)
  (data :int)
  (out :pointer))

(cffi:defcfun ("ghostty_grid_ref_hyperlink_uri" %grid-ref-hyperlink-uri) :int
  (ref :pointer)
  (buffer :pointer)
  (buffer-len :size)
  (out-written :pointer))

(cffi:defcfun ("ghostty_unicode_codepoint_width" %codepoint-width) :uint8
  (codepoint :uint32))

;;; --- mouse ------------------------------------------------------------

(cffi:defcfun ("ghostty_mouse_encoder_new" %mouse-encoder-new) :int
  (allocator :pointer)
  (out (:pointer :pointer)))

(cffi:defcfun ("ghostty_mouse_encoder_free" %mouse-encoder-free) :void
  (encoder :pointer))

(cffi:defcfun ("ghostty_mouse_encoder_set" %mouse-encoder-set) :int
  (encoder :pointer)
  (option :int)
  (value :pointer))

(cffi:defcfun ("ghostty_mouse_encoder_set_from_terminal" %mouse-encoder-sync) :int
  (encoder :pointer)
  (terminal :pointer))

(cffi:defcfun ("ghostty_mouse_encoder_encode" %mouse-encoder-encode) :int
  (encoder :pointer)
  (event :pointer)
  (buffer :pointer)
  (buffer-len :size)
  (out-written :pointer))

(cffi:defcfun ("ghostty_mouse_event_new" %mouse-event-new) :int
  (allocator :pointer)
  (out (:pointer :pointer)))

(cffi:defcfun ("ghostty_mouse_event_free" %mouse-event-free) :void
  (event :pointer))

(cffi:defcfun ("ghostty_mouse_event_set_action" %mouse-event-set-action) :int
  (event :pointer)
  (action :int))

(cffi:defcfun ("ghostty_mouse_event_set_button" %mouse-event-set-button) :int
  (event :pointer)
  (button :int))

(cffi:defcfun ("ghostty_mouse_event_clear_button" %mouse-event-clear-button) :int
  (event :pointer))

(cffi:defcfun ("ghostty_mouse_event_set_position" %mouse-event-set-position) :int
  (event :pointer)
  (position (:struct ghostty-mouse-position)))

(cffi:defcfun ("ghostty_mouse_event_get_position" %mouse-event-get-position)
    (:struct ghostty-mouse-position)
  (event :pointer))

;;; --- render state -----------------------------------------------------

(cffi:defcfun ("ghostty_render_state_new" %render-state-new) :int
  (allocator :pointer)
  (out (:pointer :pointer)))

(cffi:defcfun ("ghostty_render_state_free" %render-state-free) :void
  (state :pointer))

(cffi:defcfun ("ghostty_render_state_update" %render-state-update) :int
  (state :pointer)
  (terminal :pointer))

(cffi:defcfun ("ghostty_render_state_get" %render-state-get) :int
  (state :pointer)
  (data :int)
  (out :pointer))

(cffi:defcfun ("ghostty_render_state_clean" %render-state-clean) :int
  (state :pointer))

(cffi:defcfun ("ghostty_render_state_row_iterator_new" %row-iterator-new) :int
  (allocator :pointer)
  (out (:pointer :pointer)))

(cffi:defcfun ("ghostty_render_state_row_iterator_free" %row-iterator-free) :void
  (iterator :pointer))

(cffi:defcfun ("ghostty_render_state_row_iterator_next" %row-iterator-next) :boolean
  (iterator :pointer))

(cffi:defcfun ("ghostty_render_state_row_iterator_next_dirty" %row-iterator-next-dirty) :boolean
  (iterator :pointer)
  (out-y :pointer))

(cffi:defcfun ("ghostty_render_state_row_get" %row-get) :int
  (iterator :pointer)
  (data :int)
  (out :pointer))

(cffi:defcfun ("ghostty_render_state_row_cells_new" %row-cells-new) :int
  (allocator :pointer)
  (out (:pointer :pointer)))

(cffi:defcfun ("ghostty_render_state_row_cells_free" %row-cells-free) :void
  (cells :pointer))

(cffi:defcfun ("ghostty_render_state_row_cells_next" %row-cells-next) :boolean
  (cells :pointer))

(cffi:defcfun ("ghostty_render_state_row_cells_get" %row-cells-get) :int
  (cells :pointer)
  (data :int)
  (out :pointer))

;;; --- key encoding -----------------------------------------------------

(cffi:defcfun ("ghostty_key_encoder_new" %key-encoder-new) :int
  (allocator :pointer)
  (out (:pointer :pointer)))

(cffi:defcfun ("ghostty_key_encoder_free" %key-encoder-free) :void
  (encoder :pointer))

(cffi:defcfun ("ghostty_key_encoder_set_from_terminal" %key-encoder-set-from-terminal) :int
  (encoder :pointer)
  (terminal :pointer))

(cffi:defcfun ("ghostty_key_encoder_encode" %key-encoder-encode) :int
  (encoder :pointer)
  (event :pointer)
  (buffer :pointer)
  (buffer-len :size)
  (out-written :pointer))

(cffi:defcfun ("ghostty_key_event_new" %key-event-new) :int
  (allocator :pointer)
  (out (:pointer :pointer)))

(cffi:defcfun ("ghostty_key_event_free" %key-event-free) :void
  (event :pointer))

(cffi:defcfun ("ghostty_key_event_set_action" %key-event-set-action) :int
  (event :pointer)
  (action :int))

(cffi:defcfun ("ghostty_key_event_set_key" %key-event-set-key) :int
  (event :pointer)
  (key :int))

(cffi:defcfun ("ghostty_key_event_set_mods" %key-event-set-mods) :int
  (event :pointer)
  (mods :uint16))

(cffi:defcfun ("ghostty_key_event_set_utf8" %key-event-set-utf8) :int
  (event :pointer)
  (utf8 (:struct ghostty-string)))

(cffi:defcfun ("ghostty_key_event_set_unshifted_codepoint" %key-event-set-unshifted-codepoint) :int
  (event :pointer)
  (codepoint :uint32))

;;; --- effect callbacks --------------------------------------------------
;;;
;;; libghostty-vt notifies the embedder about replies it generated (DSR,
;;; DA, XTGETTCAP, ...) instead of writing them itself.  These dispatchers
;;; forward to Lisp functions installed by the terminal layer.

(defvar *write-pty-function* nil
  "Called as (ID DATA-POINTER LENGTH) when the terminal needs to reply to
the program.  Must write the bytes to the PTY.")

(defvar *bell-function* nil
  "Called as (ID) on BEL.")

(defvar *title-function* nil
  "Called as (ID) when the terminal title changes.")

(defvar *clipboard-write-function* nil
  "Called as (ID LOCATION CONTENTS) for a clipboard write request.
CONTENTS is an alist of (MIME . DATA).  The function returns true when the
clipboard write was accepted, false to answer UNSUPPORTED.")

(defun set-write-pty-function (function)
  (setf *write-pty-function* function))

(defun set-bell-function (function)
  (setf *bell-function* function))

(defun set-title-function (function)
  (setf *title-function* function))

(defun set-clipboard-write-function (function)
  (setf *clipboard-write-function* function))

(defun userdata-id (userdata)
  "The integer terminal id we stored in the callback userdata pointer."
  (cffi:pointer-address userdata))

(cffi:defcallback cb-write-pty :void
    ((terminal :pointer) (userdata :pointer) (data :pointer) (len :size))
  (declare (ignore terminal))
  (when *write-pty-function*
    (funcall *write-pty-function* (userdata-id userdata) data len)))

(cffi:defcallback cb-bell :void
    ((terminal :pointer) (userdata :pointer))
  (declare (ignore terminal))
  (when *bell-function*
    (funcall *bell-function* (userdata-id userdata))))

(cffi:defcallback cb-title :void
    ((terminal :pointer) (userdata :pointer))
  (declare (ignore terminal))
  (when *title-function*
    (funcall *title-function* (userdata-id userdata))))

(defun foreign-string-value (string-struct)
  "Decode a GhosttyString structure at STRING-STRUCT."
  (cffi:with-foreign-slots ((ptr len) string-struct (:struct ghostty-string))
    (if (zerop len)
        ""
        (handler-case
            (cffi:foreign-string-to-lisp ptr :count len :encoding :utf-8)
          (error ()
            (cffi:foreign-string-to-lisp ptr :count len :encoding :iso-8859-1))))))

(cffi:defcallback cb-clipboard-write :void
    ((terminal :pointer) (userdata :pointer) (write :pointer))
  (declare (ignore terminal))
  (let* ((contents-len (cffi:foreign-slot-value
                        write '(:struct ghostty-clipboard-write) 'contents-len))
         (contents-ptr (cffi:foreign-slot-value
                        write '(:struct ghostty-clipboard-write) 'contents))
         (location (cffi:foreign-slot-value
                    write '(:struct ghostty-clipboard-write) 'location))
         (contents
           (loop :for i :below contents-len
                 :for item := (cffi:mem-aptr contents-ptr
                                             '(:struct ghostty-clipboard-content)
                                             i)
                 :collect (cons (foreign-string-value
                                 (cffi:foreign-slot-pointer
                                  item '(:struct ghostty-clipboard-content) 'mime))
                                (foreign-string-value
                                 (cffi:foreign-slot-pointer
                                  item '(:struct ghostty-clipboard-content) 'data)))))
         (accepted (and *clipboard-write-function*
                        (funcall *clipboard-write-function*
                                 (userdata-id userdata)
                                 location
                                 contents)))
         (reply-fn (cffi:foreign-slot-value
                    write '(:struct ghostty-clipboard-write) 'reply)))
    (unless (or (null reply-fn) (cffi:null-pointer-p reply-fn))
      (cffi:with-foreign-object (reply '(:struct ghostty-clipboard-write-reply))
        (setf (cffi:foreign-slot-value
               reply '(:struct ghostty-clipboard-write-reply) 'size)
              (cffi:foreign-type-size '(:struct ghostty-clipboard-write-reply))
              (cffi:foreign-slot-value
               reply '(:struct ghostty-clipboard-write-reply) 'result)
              (if accepted +clipboard-write-success+ +clipboard-write-unsupported+)
              (cffi:foreign-slot-value
               reply '(:struct ghostty-clipboard-write-reply) 'remember)
              nil)
        (cffi:foreign-funcall-pointer reply-fn nil
                                      :pointer write
                                      :pointer reply
                                      :void)))))

(cffi:defcallback cb-device-attributes :boolean
    ((terminal :pointer) (userdata :pointer) (attributes :pointer))
  "Answer a device-attributes query with libghostty-vt's defaults."
  (declare (ignore terminal userdata attributes))
  nil)

;;; --- convenience wrappers ---------------------------------------------

(defun check (result message)
  "Signal an error unless RESULT is GHOSTTY_SUCCESS."
  (unless (= result +result-success+)
    (error "libghostty-vt: ~A (result ~D)" message result))
  result)

(defun terminal-new (cols rows)
  "Create a terminal of COLS by ROWS.  Returns the GhosttyTerminal handle."
  (cffi:with-foreign-object (out :pointer)
    (check (%terminal-new (cffi:null-pointer) out cols rows)
           "could not create terminal")
    (cffi:mem-ref out :pointer)))

(defun terminal-free (terminal)
  (when (and terminal (not (cffi:null-pointer-p terminal)))
    (%terminal-free terminal)))

(defun terminal-resize (terminal cols rows)
  "Resize the terminal's grid.  Cell pixel sizes are 1x1 because Lem does
not expose a portable character pixel size."
  (%terminal-resize terminal cols rows 1 1))

(defun terminal-write-vt (terminal data length)
  "Feed LENGTH bytes of DATA (a foreign pointer) to the VT parser."
  (%terminal-vt-write terminal data length))

(defun terminal-set (terminal option value)
  (%terminal-set terminal option value))

(defun terminal-get (terminal data out)
  (%terminal-get terminal data out))

(defun terminal-scroll-viewport (terminal tag delta)
  "Scroll the viewport.  TAG is +SCROLL-DELTA+ for a relative scroll, or
+SCROLL-TOP+/+SCROLL-BOTTOM+ for an absolute move (DELTA is ignored)."
  (cffi:with-foreign-object (behavior '(:struct ghostty-scroll-viewport))
    (setf (cffi:foreign-slot-value behavior '(:struct ghostty-scroll-viewport) 'tag)
          tag
          (cffi:foreign-slot-value behavior '(:struct ghostty-scroll-viewport) 'delta)
          (or delta 0))
    (%terminal-scroll-viewport terminal
                               (cffi:mem-ref behavior '(:struct ghostty-scroll-viewport)))))

(defun terminal-cols (terminal)
  (cffi:with-foreign-object (out :uint16)
    (terminal-get terminal +term-data-cols+ out)
    (cffi:mem-ref out :uint16)))

(defun terminal-rows (terminal)
  (cffi:with-foreign-object (out :uint16)
    (terminal-get terminal +term-data-rows+ out)
    (cffi:mem-ref out :uint16)))

(defun terminal-total-rows (terminal)
  (cffi:with-foreign-object (out :size)
    (terminal-get terminal +term-data-total-rows+ out)
    (cffi:mem-ref out :size)))

(defun terminal-scrollback-rows (terminal)
  (cffi:with-foreign-object (out :size)
    (terminal-get terminal +term-data-scrollback-rows+ out)
    (cffi:mem-ref out :size)))

(defun terminal-viewport-active-p (terminal)
  "True when the viewport is following the active area (not scrolled back)."
  (cffi:with-foreign-object (out :uint8)
    (terminal-get terminal +term-data-viewport-active+ out)
    (not (zerop (cffi:mem-ref out :uint8)))))

(defun terminal-mode-value (terminal mode)
  "Return the boolean value of terminal MODE (a ghostty_mode_new value)."
  (cffi:with-foreign-object (out '(:struct ghostty-mode-config))
    (setf (cffi:foreign-slot-value out '(:struct ghostty-mode-config) 'mode) mode)
    (when (= (terminal-get terminal +term-data-mode+ out) +result-success+)
      (not (zerop (cffi:foreign-slot-value out '(:struct ghostty-mode-config) 'value))))))

(defun terminal-title (terminal)
  "Return the terminal's current title as a Lisp string, or NIL."
  (cffi:with-foreign-object (out '(:struct ghostty-string))
    (when (= (terminal-get terminal +term-data-title+ out) +result-success+)
      (cffi:with-foreign-slots ((ptr len) out (:struct ghostty-string))
        (when (plusp len)
          (cffi:foreign-string-to-lisp ptr :count len :encoding :utf-8))))))

(defun terminal-mouse-tracking-p (terminal)
  (cffi:with-foreign-object (out :uint8)
    (and (= (terminal-get terminal +term-data-mouse-tracking+ out)
            +result-success+)
         (not (zerop (cffi:mem-ref out :uint8))))))

(defun terminal-set-terminfo-name (terminal name)
  "Tell the terminal what TERM name to report for XTGETTCAP TN."
  (cffi:with-foreign-string (ptr name)
    (cffi:with-foreign-object (value '(:struct ghostty-string))
      (setf (cffi:foreign-slot-value value '(:struct ghostty-string) 'ptr) ptr
            (cffi:foreign-slot-value value '(:struct ghostty-string) 'len)
            (length name))
      (terminal-set terminal +opt-terminfo-name+ value))))

(defun make-viewport-point (x y)
  "Allocate a GhosttyPoint for viewport cell X, Y.  Caller frees."
  (let ((point (cffi:foreign-alloc '(:struct ghostty-point))))
    (setf (cffi:foreign-slot-value point '(:struct ghostty-point) 'tag)
          +point-tag-viewport+
          (cffi:foreign-slot-value point '(:struct ghostty-point) 'x) x
          (cffi:foreign-slot-value point '(:struct ghostty-point) 'y) y)
    point))

(defun with-viewport-grid-ref (terminal x y function)
  (let ((point (make-viewport-point x y)))
    (unwind-protect
         (cffi:with-foreign-object (ref '(:struct ghostty-grid-ref))
           (when (= (%terminal-grid-ref terminal
                                        (cffi:mem-ref point '(:struct ghostty-point))
                                        ref)
                    +result-success+)
             (funcall function ref)))
      (cffi:foreign-free point))))

(defun terminal-grid-ref-hyperlink-uri (terminal x y)
  "Return the OSC 8 URI of viewport cell X, Y, or NIL."
  (with-viewport-grid-ref
      terminal x y
    (lambda (ref)
      (cffi:with-foreign-object (needed :size)
        (let ((result (%grid-ref-hyperlink-uri ref (cffi:null-pointer) 0 needed)))
          (cond
            ((zerop (cffi:mem-ref needed :size))
             nil)
            ((= result +result-out-of-space+)
             (let ((len (cffi:mem-ref needed :size)))
               (cffi:with-foreign-object (buffer :uint8 len)
                 (when (= (%grid-ref-hyperlink-uri ref buffer len needed)
                          +result-success+)
                   (cffi:foreign-string-to-lisp buffer :count len :encoding :utf-8)))))
            (t nil)))))))

(defun terminal-row-has-hyperlink-p (terminal y)
  "True when viewport row Y contains any OSC 8 hyperlink."
  (with-viewport-grid-ref
      terminal 0 y
    (lambda (ref)
      (cffi:with-foreign-object (row :uint64)
        (when (= (%grid-ref-row ref row) +result-success+)
          (cffi:with-foreign-object (flag :uint8)
            (and (= (%row-data-get (cffi:mem-ref row :uint64) 5 flag)
                    +result-success+)
                 (not (zerop (cffi:mem-ref flag :uint8))))))))))

;;; --- mouse wrappers ---------------------------------------------------

(defun mouse-encoder-new ()
  (cffi:with-foreign-object (out :pointer)
    (check (%mouse-encoder-new (cffi:null-pointer) out)
           "could not create mouse encoder")
    (cffi:mem-ref out :pointer)))

(defun mouse-encoder-free (encoder)
  (when (and encoder (not (cffi:null-pointer-p encoder)))
    (%mouse-encoder-free encoder)))

(defun mouse-encoder-set-size (encoder cols rows)
  "Set the encoder geometry to COLS by ROWS cells of one pixel."
  (cffi:with-foreign-object (size '(:struct ghostty-mouse-encoder-size))
    (setf (cffi:foreign-slot-value size '(:struct ghostty-mouse-encoder-size) 'size)
          (cffi:foreign-type-size '(:struct ghostty-mouse-encoder-size))
          (cffi:foreign-slot-value size '(:struct ghostty-mouse-encoder-size) 'screen-width)
          cols
          (cffi:foreign-slot-value size '(:struct ghostty-mouse-encoder-size) 'screen-height)
          rows
          (cffi:foreign-slot-value size '(:struct ghostty-mouse-encoder-size) 'cell-width)
          1
          (cffi:foreign-slot-value size '(:struct ghostty-mouse-encoder-size) 'cell-height)
          1
          (cffi:foreign-slot-value size '(:struct ghostty-mouse-encoder-size) 'padding-top)
          0
          (cffi:foreign-slot-value size '(:struct ghostty-mouse-encoder-size) 'padding-bottom)
          0
          (cffi:foreign-slot-value size '(:struct ghostty-mouse-encoder-size) 'padding-right)
          0
          (cffi:foreign-slot-value size '(:struct ghostty-mouse-encoder-size) 'padding-left)
          0)
    (%mouse-encoder-set encoder +mouse-encoder-opt-size+ size)
    (cffi:with-foreign-object (flag :uint8)
      (setf (cffi:mem-ref flag :uint8) 1)
      (%mouse-encoder-set encoder +mouse-encoder-opt-track-last-cell+ flag))))

(defun mouse-encoder-sync (encoder terminal)
  (%mouse-encoder-sync encoder terminal))

(defun mouse-encoder-encode (encoder event buffer buffer-len out-written)
  (%mouse-encoder-encode encoder event buffer buffer-len out-written))

(defun mouse-event-new ()
  (cffi:with-foreign-object (out :pointer)
    (check (%mouse-event-new (cffi:null-pointer) out)
           "could not create mouse event")
    (cffi:mem-ref out :pointer)))

(defun mouse-event-free (event)
  (when (and event (not (cffi:null-pointer-p event)))
    (%mouse-event-free event)))

(defun mouse-event-set-press (event button x y)
  (check (%mouse-event-set-action event +mouse-action-press+) "mouse action")
  (check (%mouse-event-set-button event button) "mouse button")
  (set-position event x y))

(defun mouse-event-set-release (event button x y)
  (check (%mouse-event-set-action event +mouse-action-release+) "mouse action")
  (check (%mouse-event-set-button event button) "mouse button")
  (set-position event x y))

(defun mouse-event-set-motion (event button x y)
  (check (%mouse-event-set-action event +mouse-action-motion+) "mouse action")
  (if button
      (check (%mouse-event-set-button event button) "mouse button")
      (%mouse-event-clear-button event))
  (set-position event x y))

(defun mouse-event-clear-button (event)
  (%mouse-event-clear-button event))

(defun mouse-event-set-position (event x y)
  (set-position event x y))

(defun set-position (event x y)
  (cffi:with-foreign-object (position '(:struct ghostty-mouse-position))
    (setf (cffi:foreign-slot-value position '(:struct ghostty-mouse-position) 'x)
          (float x)
          (cffi:foreign-slot-value position '(:struct ghostty-mouse-position) 'y)
          (float y))
    (%mouse-event-set-position event
                               (cffi:mem-ref position '(:struct ghostty-mouse-position)))))

;;; --- struct accessors -------------------------------------------------
;;;
;;; Slot names are interned in this package, so other packages must go
;;; through these accessors rather than foreign-slot-value with a symbol of
;;; their own.

(declaim (inline buffer-reset))
(defun buffer-reset (buffer pointer capacity)
  "Point the GhosttyBuffer BUFFER at POINTER with CAPACITY bytes and len 0."
  (setf (cffi:foreign-slot-value buffer '(:struct ghostty-buffer) 'ptr) pointer
        (cffi:foreign-slot-value buffer '(:struct ghostty-buffer) 'cap) capacity
        (cffi:foreign-slot-value buffer '(:struct ghostty-buffer) 'len) 0)
  buffer)

(defun buffer-len (buffer)
  (cffi:foreign-slot-value buffer '(:struct ghostty-buffer) 'len))

(defun style-flags (style)
  (cffi:foreign-slot-value style '(:struct ghostty-style) 'flags))

(defun style-fg (style)
  "Return (values TAG RED GREEN BLUE) for STYLE's foreground."
  (cffi:with-foreign-slots ((fg-tag fg-r fg-g fg-b) style (:struct ghostty-style))
    (values fg-tag fg-r fg-g fg-b)))

(defun style-bg (style)
  "Return (values TAG RED GREEN BLUE) for STYLE's background."
  (cffi:with-foreign-slots ((bg-tag bg-r bg-g bg-b) style (:struct ghostty-style))
    (values bg-tag bg-r bg-g bg-b)))

(defun cursor-viewport-available-p (cursor)
  (plusp (cffi:foreign-slot-value cursor '(:struct ghostty-cursor)
                                  'viewport-has-value)))

(defun cursor-x (cursor)
  (cffi:foreign-slot-value cursor '(:struct ghostty-cursor) 'viewport-x))

(defun cursor-y (cursor)
  (cffi:foreign-slot-value cursor '(:struct ghostty-cursor) 'viewport-y))

(defun colors-palette (colors)
  "Foreign pointer to the 256-entry RGB palette in COLORS."
  (cffi:foreign-slot-pointer colors '(:struct ghostty-render-colors) 'palette))

(defun codepoint-width (codepoint)
  "Display width of CODEPOINT (0, 1 or 2 cells)."
  (%codepoint-width codepoint))

;;; --- render state wrappers --------------------------------------------

(defun render-state-new ()
  (cffi:with-foreign-object (out :pointer)
    (check (%render-state-new (cffi:null-pointer) out)
           "could not create render state")
    (cffi:mem-ref out :pointer)))

(defun render-state-free (state)
  (when (and state (not (cffi:null-pointer-p state)))
    (%render-state-free state)))

(defun render-state-update (state terminal)
  "Update STATE from TERMINAL.  Returns :FALSE, :PARTIAL or :FULL."
  (check (%render-state-update state terminal) "could not update render state")
  (cffi:with-foreign-object (out :int)
    (check (%render-state-get state +render-data-dirty+ out)
           "could not read render dirty state")
    (case (cffi:mem-ref out :int)
      (0 :false)
      (1 :partial)
      (2 :full)
      (t :partial))))

(defun render-state-clean (state)
  (%render-state-clean state))

(defun render-state-size (state)
  "Return (values COLS ROWS) of the viewport captured in STATE."
  (cffi:with-foreign-objects ((cols :uint16) (rows :uint16))
    (check (%render-state-get state +render-data-cols+ cols) "no render cols")
    (check (%render-state-get state +render-data-rows+ rows) "no render rows")
    (values (cffi:mem-ref cols :uint16)
            (cffi:mem-ref rows :uint16))))

(defun render-state-get (state data out)
  (%render-state-get state data out))

(defun render-state-cursor (state cursor-out)
  "Fill CURSOR-OUT (a (:struct ghostty-cursor)) from STATE."
  (setf (cffi:foreign-slot-value cursor-out '(:struct ghostty-cursor) 'size)
        (cffi:foreign-type-size '(:struct ghostty-cursor)))
  (%render-state-get state +render-data-cursor+ cursor-out))

(defun render-state-colors (state colors-out)
  "Fill COLORS-OUT (a (:struct ghostty-render-colors)) from STATE."
  (setf (cffi:foreign-slot-value colors-out '(:struct ghostty-render-colors) 'size)
        (cffi:foreign-type-size '(:struct ghostty-render-colors)))
  (%render-state-get state +render-data-colors+ colors-out))

(defun row-iterator-new ()
  (cffi:with-foreign-object (out :pointer)
    (check (%row-iterator-new (cffi:null-pointer) out)
           "could not create row iterator")
    (cffi:mem-ref out :pointer)))

(defun row-iterator-free (iterator)
  (when (and iterator (not (cffi:null-pointer-p iterator)))
    (%row-iterator-free iterator)))

(defun row-iterator-next (iterator)
  (%row-iterator-next iterator))

(defun row-iterator-next-dirty (iterator y-out)
  (%row-iterator-next-dirty iterator y-out))

(defun row-cells-new ()
  (cffi:with-foreign-object (out :pointer)
    (check (%row-cells-new (cffi:null-pointer) out)
           "could not create row cells")
    (cffi:mem-ref out :pointer)))

(defun row-cells-free (cells)
  (when (and cells (not (cffi:null-pointer-p cells)))
    (%row-cells-free cells)))

(defun row-cells-next (cells)
  (%row-cells-next cells))

(defun row-cells-style (cells style-out)
  "Read the current cell's GhosttyStyle into STYLE-OUT."
  (%row-cells-get cells +cells-data-style+ style-out))

(defun row-cells-foreground (cells rgb-out)
  "Read the resolved foreground color into RGB-OUT (three uint8 slots).
Returns T when the cell has its own foreground, NIL for the default."
  (= (%row-cells-get cells +cells-data-fg+ rgb-out) +result-success+))

(defun row-cells-background (cells rgb-out)
  "Read the resolved background color into RGB-OUT.
Returns T when the cell has its own background, NIL for the default."
  (= (%row-cells-get cells +cells-data-bg+ rgb-out) +result-success+))

(defun row-cells-selected-p (cells)
  (cffi:with-foreign-object (out :uint8)
    (and (= (%row-cells-get cells +cells-data-selected+ out) +result-success+)
         (not (zerop (cffi:mem-ref out :uint8))))))

(defun row-cells-graphemes (cells buffer-out)
  "Fill BUFFER-OUT (a (:struct ghostty-buffer)) with the current cell's
UTF-8 text.  The caller owns the destination bytes."
  (%row-cells-get cells +cells-data-graphemes-utf8+ buffer-out))

;;; --- render state row wrapper -----------------------------------------

(defun row-get (iterator data out)
  (%row-get iterator data out))

;;; --- key encoder wrappers ---------------------------------------------

(defun key-encoder-new ()
  (cffi:with-foreign-object (out :pointer)
    (check (%key-encoder-new (cffi:null-pointer) out)
           "could not create key encoder")
    (cffi:mem-ref out :pointer)))

(defun key-encoder-free (encoder)
  (when (and encoder (not (cffi:null-pointer-p encoder)))
    (%key-encoder-free encoder)))

(defun key-encoder-sync (encoder terminal)
  "Copy the terminal's current keyboard modes into ENCODER."
  (%key-encoder-set-from-terminal encoder terminal))

(defun key-encoder-encode (encoder event buffer buffer-len written-out)
  (%key-encoder-encode encoder event buffer buffer-len written-out))

(defun key-event-new ()
  (cffi:with-foreign-object (out :pointer)
    (check (%key-event-new (cffi:null-pointer) out)
           "could not create key event")
    (cffi:mem-ref out :pointer)))

(defun key-event-free (event)
  (when (and event (not (cffi:null-pointer-p event)))
    (%key-event-free event)))

(defun key-event-set (event &key action key mods utf8 utf8-length unshifted-codepoint)
  "Configure EVENT.  UTF8 must be a foreign pointer that stays valid until
the event is freed or its text is set again (libghostty-vt does not copy)."
  (when action
    (%key-event-set-action event action))
  (when key
    (%key-event-set-key event key))
  (when mods
    (%key-event-set-mods event mods))
  (when (or utf8 (eql utf8-length 0))
    (cffi:with-foreign-object (string '(:struct ghostty-string))
      (setf (cffi:foreign-slot-value string '(:struct ghostty-string) 'ptr)
            (or utf8 (cffi:null-pointer))
            (cffi:foreign-slot-value string '(:struct ghostty-string) 'len)
            (or utf8-length 0))
      (%key-event-set-utf8 event (cffi:mem-ref string '(:struct ghostty-string)))))
  (when unshifted-codepoint
    (%key-event-set-unshifted-codepoint event unshifted-codepoint)))

(defun key-code (name)
  "GhosttyKey for a Lem key name, or NIL when the key has no logical code."
  (cdr (assoc name *key-codes* :test #'string=)))
