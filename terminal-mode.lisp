(uiop:define-package :lem-ghostty-terminal/terminal-mode
  (:use :cl :lem)
  (:local-nicknames (:terminal :lem-ghostty-terminal/terminal))
  (:export :terminal-mode
           :terminal-copy-mode
           :ghostty-terminal
           :ghostty-terminal-copy-mode-on
           :ghostty-terminal-copy-mode-off
           :ghostty-terminal-resize
           :ghostty-terminal-scroll-up
           :ghostty-terminal-scroll-down))
(in-package :lem-ghostty-terminal/terminal-mode)

;;; --- mode dispatch table ----------------------------------------------

;;; Commands that must keep their normal Lem meaning inside the terminal:
;;; window management, prompts, and the terminal's own control commands.
(defvar *bypass-commands*
  '(next-window
    previous-window
    window-move-up
    window-move-down
    window-move-left
    window-move-right
    split-active-window-vertically
    split-active-window-horizontally
    delete-other-windows
    delete-active-window
    select-buffer
    kill-buffer
    find-file
    execute-command
    ghostty-terminal-resize
    ghostty-terminal-copy-mode-on
    ghostty-terminal-copy-mode-off
    ghostty-terminal-scroll-up
    ghostty-terminal-scroll-down
    lem-core::<mouse-motion-event>
    lem-core::<mouse-event>
    lem/frame-multiplexer:frame-multiplexer-advice))

;;; --- keymaps ----------------------------------------------------------

(defvar *terminal-mode-keymap* (make-keymap :description "Terminal"))
(defvar *terminal-copy-mode-keymap* (make-keymap :description "Terminal (Copy)"))

(define-key *terminal-mode-keymap* 'self-insert 'terminal-input)
(define-key *terminal-mode-keymap* 'undefined-key 'terminal-input)
(define-key *terminal-mode-keymap* "C-h" 'terminal-input)

;; Control keys that Lem would otherwise treat as editor bindings (C-c and
;; C-x are prefixes, C-s/C-q are flow control, C-z suspends, C-\ is a
;; prefix too) must reach the program.  This is why the terminal is opened
;; from outside with a prefix of your choice, not with C-c inside it.
(dolist (key '("C-c" "C-x" "C-z" "C-s" "C-q" "C-g" "C-\\"))
  (define-key *terminal-mode-keymap* key 'terminal-input))

;; C-x is needed by programs, so copy mode has its own binding.
(define-key *terminal-mode-keymap* "M-[" 'ghostty-terminal-copy-mode-on)
(define-key *terminal-mode-keymap* "PageUp" 'ghostty-terminal-scroll-up)
(define-key *terminal-mode-keymap* "PageDown" 'ghostty-terminal-scroll-down)
(define-key *terminal-copy-mode-keymap* "Escape" 'ghostty-terminal-copy-mode-off)

;;; --- commands and helpers --------------------------------------------

(defun buffer-terminal (buffer)
  (buffer-value buffer 'ghostty-terminal))

(defun (setf buffer-terminal) (terminal buffer)
  (setf (buffer-value buffer 'ghostty-terminal) terminal))

(defun get-current-terminal ()
  (buffer-terminal (current-buffer)))

(defun make-terminal-buffer (directory)
  "Create a terminal buffer in DIRECTORY."
  (let* ((buffer (make-buffer (unique-buffer-name "*Terminal*")
                              :enable-undo-p nil))
         (terminal (terminal:create :cols 80 :rows 24
                                    :buffer buffer
                                    :directory directory)))
    (setf (buffer-terminal buffer) terminal)
    (change-buffer-mode buffer 'terminal-mode)
    buffer))

(define-command ghostty-terminal (always-create-terminal-p) (:universal-nil)
  "Open a ghostty-backed terminal.

The terminal runs the user's shell in the current buffer's directory.  With
a universal argument a new terminal is always created; otherwise an existing
terminal buffer is reused."
  (let ((directory (or (buffer-directory (current-buffer))
                       (uiop:getcwd))))
    (if always-create-terminal-p
        (create-terminal directory)
        (alexandria:if-let ((buffer (terminal:find-terminal-buffer)))
          (setf (current-window) (pop-to-buffer buffer))
          (create-terminal directory)))))

(defun create-terminal (directory)
  (let* ((buffer (make-terminal-buffer directory))
         (window (pop-to-buffer buffer)))
    (resize-terminal (buffer-terminal buffer) window)
    (setf (current-window) window)))

(defun on-kill-buffer (buffer)
  (alexandria:when-let ((terminal (buffer-terminal buffer)))
    (terminal:destroy terminal)))

(define-major-mode terminal-mode ()
    (:name "Terminal"
     :keymap *terminal-mode-keymap*)
  "Major mode for a terminal buffer drawn by libghostty-vt."
  (setf (buffer-read-only-p (current-buffer)) t)
  (setf (variable-value 'highlight-line :buffer (current-buffer)) nil)
  (setf (variable-value 'line-wrap :buffer (current-buffer)) nil)
  (setf (variable-value 'lem/show-paren:enable :buffer (current-buffer)) nil)
  (add-hook (variable-value 'kill-buffer-hook :buffer (current-buffer))
            'on-kill-buffer)
  (alexandria:when-let ((terminal (get-current-terminal)))
    (terminal:copy-mode-off terminal)))

(define-major-mode terminal-copy-mode ()
    (:name "Terminal (Copy)"
     :keymap *terminal-copy-mode-keymap*)
  "Major mode that freezes a terminal buffer so its text can be copied.

Rendering stops while this mode is active, so the shell cannot overwrite the
text under the selection."
  (setf (buffer-read-only-p (current-buffer)) t)
  (setf (variable-value 'highlight-line :buffer (current-buffer)) nil)
  (setf (variable-value 'line-wrap :buffer (current-buffer)) nil)
  (setf (variable-value 'lem/show-paren:enable :buffer (current-buffer)) nil)
  (add-hook (variable-value 'kill-buffer-hook :buffer (current-buffer))
            'on-kill-buffer)
  (alexandria:when-let ((terminal (get-current-terminal)))
    (terminal:copy-mode-on terminal)))

(define-command terminal-input () ()
  "Send the keys that invoked this command to the terminal."
  (alexandria:when-let ((terminal (get-current-terminal)))
    (dolist (key (last-read-key-sequence))
      (terminal:send-key terminal key))))

(define-command ghostty-terminal-copy-mode-on () ()
  "Enter copy mode: stop rendering and keep the current screen."
  (when (get-current-terminal)
    (terminal-copy-mode)))

(define-command ghostty-terminal-copy-mode-off () ()
  "Leave copy mode and resume rendering."
  (when (get-current-terminal)
    (terminal-mode)
    (adjust-current-point)))

(defun adjust-current-point ()
  (alexandria:when-let ((terminal (get-current-terminal)))
    (terminal:adjust-point terminal)))

(defun scroll-terminal (delta)
  (alexandria:when-let ((terminal (get-current-terminal)))
    (terminal:scroll-viewport terminal delta)))

(defun scroll-row-count (argument)
  "Rows requested by a scroll command, or NIL for its default page.

Lem's mouse-wheel handler calls SCROLL-DOWN with (- WHEEL-Y *SCROLL-SPEED*),
so the argument carries the direction; key bindings such as PageUp leave it
NIL and mean 'one page'.  A universal argument may arrive as a list."
  (cond ((integerp argument) argument)
        ((and (consp argument) (integerp (first argument)))
         (first argument))
        (t nil)))

(define-command ghostty-terminal-scroll-up () ()
  "Scroll the terminal viewport one page up (into scrollback)."
  (scroll-terminal (- (max 1 (1- (window-height (current-window)))))))

(define-command ghostty-terminal-scroll-down () ()
  "Scroll the terminal viewport one page down."
  (scroll-terminal (max 1 (1- (window-height (current-window))))))

(defun resize-terminal (terminal window)
  (terminal:resize terminal
                   (1- (window-height window))
                   (window-width window)))

(define-command ghostty-terminal-resize () ()
  "Match the terminal grid to the current window."
  (alexandria:when-let ((terminal (get-current-terminal))
                        (window (current-window)))
    (resize-terminal terminal window)))

(defun on-window-size-change (window)
  (alexandria:when-let ((terminal (buffer-terminal (window-buffer window))))
    (resize-terminal terminal window)))

(add-hook *window-size-change-functions* 'on-window-size-change)
(add-hook *post-command-hook* 'ghostty-terminal-resize)

;;; --- mode dispatch ----------------------------------------------------

(defmethod execute ((mode terminal-mode) command argument)
  "Route typing to the terminal; page scrolling moves the terminal viewport.

Other commands (window management, prompts) keep their normal meaning.  Any
remaining command is treated as typed input, matching how a terminal behaves:
pressing a key must reach the shell rather than run an editor command."
  (cond
    ((member command *bypass-commands* :test #'typep)
     (call-next-method))
    ((typep command 'scroll-up)
     (let ((rows (scroll-row-count argument)))
       (if rows
           (scroll-terminal (- rows))
           (ghostty-terminal-scroll-up))))
    ((typep command 'scroll-down)
     (let ((rows (scroll-row-count argument)))
       (if rows
           (scroll-terminal rows)
           (ghostty-terminal-scroll-down))))
    (t
     (terminal-input))))

(defmethod lem-core:paste-using-mode ((mode terminal-mode) string)
  "Send pasted text to the program, using bracketed paste when enabled."
  (alexandria:when-let ((terminal (get-current-terminal)))
    (terminal:send-text terminal string)))
