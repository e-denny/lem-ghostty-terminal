(uiop:define-package :lem-ghostty-terminal/terminal-mode
  (:use :cl :lem)
  (:local-nicknames (:terminal :lem-ghostty-terminal/terminal))
  (:export :terminal-mode
           :terminal-char-mode
           :terminal-copy-mode
           :*keymap-exceptions*
           :ghostty-terminal
           :ghostty-terminal-copy-mode-on
           :ghostty-terminal-copy-mode-off
           :ghostty-terminal-send-interrupt
           :ghostty-terminal-send-suspend
           :ghostty-terminal-send-eof
           :ghostty-terminal-send-quit
           :ghostty-terminal-resize
           :ghostty-terminal-scroll-up
           :ghostty-terminal-scroll-down))
(in-package :lem-ghostty-terminal/terminal-mode)

;;; --- mode dispatch table ----------------------------------------------

;;; Commands that must keep their normal Lem meaning inside the terminal:
;;; window management, prompts, mode switches and the terminal's own control
;;; commands.
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
    terminal-mode
    terminal-char-mode
    terminal-copy-mode
    ghostty-terminal-resize
    ghostty-terminal-copy-mode-on
    ghostty-terminal-copy-mode-off
    ghostty-terminal-scroll-up
    ghostty-terminal-scroll-down
    lem-core::<mouse-motion-event>
    lem-core::<mouse-event>
    lem/frame-multiplexer:frame-multiplexer-advice))

;;; --- keymaps ----------------------------------------------------------

(defparameter *keymap-exceptions*
  '("C-c" "C-x" "C-u" "M-x" "M-:" "C-\\")
  "Keys that stay Lem's in semi-char mode.

Semi-char mode is the default: everything else is sent to the program,
but a key sequence that starts with one of these keys is left to Lem, so
C-x C-c quits the editor, M-x reaches the command loop, and so on.  Char
mode ignores this list and sends every key to the program.

C-h is deliberately not listed: Lem binds it to `delete-previous-char',
and terminals commonly send backspace as ^H, so it has to reach the shell.
The C-c prefix carries the terminal's own control commands, so removing
\"C-c\" from this list also makes them unreachable from semi-char mode.")

(defvar *terminal-mode-keymap* (make-keymap :description "Terminal"))
(defvar *terminal-char-mode-keymap* (make-keymap :description "Terminal (Char)"))
(defvar *terminal-copy-mode-keymap* (make-keymap :description "Terminal (Copy)"))

;; Plain characters are not bound in either input keymap; they resolve
;; through the undefined-key hook and are remapped to TERMINAL-INPUT.
(define-key *terminal-mode-keymap* 'self-insert 'terminal-input)
(define-key *terminal-mode-keymap* 'undefined-key 'terminal-input)
(define-key *terminal-char-mode-keymap* 'self-insert 'terminal-input)
(define-key *terminal-char-mode-keymap* 'undefined-key 'terminal-input)

;; Control keys that semi-char mode still sends raw.  C-c and C-x are
;; exceptions (they stay Lem prefixes); C-\ is an exception too and is
;; available as C-c C-\ below.
(dolist (key '("C-z" "C-s" "C-q" "C-g"))
  (define-key *terminal-mode-keymap* key 'terminal-input))

;; C-c is reserved in semi-char mode for terminal control, following the
;; eat.el/Ghostel convention.  Sequences not listed here (for example a
;; user's own C-c t) fall through to the normal Lem binding.
(define-key *terminal-mode-keymap* "C-c C-c" 'ghostty-terminal-send-interrupt)
(define-key *terminal-mode-keymap* "C-c C-z" 'ghostty-terminal-send-suspend)
(define-key *terminal-mode-keymap* "C-c C-d" 'ghostty-terminal-send-eof)
(define-key *terminal-mode-keymap* "C-c C-\\" 'ghostty-terminal-send-quit)
(define-key *terminal-mode-keymap* "C-c C-t" 'ghostty-terminal-copy-mode-on)
(define-key *terminal-mode-keymap* "C-c M-d" 'terminal-char-mode)
(define-key *terminal-mode-keymap* "C-c C-j" 'terminal-mode)

;; Copy mode, from semi-char.  M-[ is kept as the quick binding; inside
;; copy mode Escape returns to the live terminal.
(define-key *terminal-mode-keymap* "M-[" 'ghostty-terminal-copy-mode-on)
(define-key *terminal-mode-keymap* "PageUp" 'ghostty-terminal-scroll-up)
(define-key *terminal-mode-keymap* "PageDown" 'ghostty-terminal-scroll-down)

;; Char mode sends everything, including the semi-char exceptions.  Each
;; key is a leaf binding, so C-x is sent immediately instead of opening a
;; prefix.  M-Return is the single escape hatch, as in Ghostel.
(dolist (key *keymap-exceptions*)
  (define-key *terminal-char-mode-keymap* key 'terminal-input))
(define-key *terminal-char-mode-keymap* "M-Return" 'terminal-mode)
;; PageUp/PageDown belong to the program in char mode.  Binding them here
;; also keeps the mode dispatch from turning them into viewport scrolls.
(define-key *terminal-char-mode-keymap* "PageUp" 'terminal-input)
(define-key *terminal-char-mode-keymap* "PageDown" 'terminal-input)

(define-key *terminal-copy-mode-keymap* "Escape" 'ghostty-terminal-copy-mode-off)
(define-key *terminal-copy-mode-keymap* "C-c C-j" 'terminal-mode)
(define-key *terminal-copy-mode-keymap* "C-c C-t" 'ghostty-terminal-copy-mode-off)

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

(defun initialize-terminal-buffer ()
  (setf (buffer-read-only-p (current-buffer)) t)
  (setf (variable-value 'highlight-line :buffer (current-buffer)) nil)
  (setf (variable-value 'line-wrap :buffer (current-buffer)) nil)
  (setf (variable-value 'lem/show-paren:enable :buffer (current-buffer)) nil)
  (add-hook (variable-value 'kill-buffer-hook :buffer (current-buffer))
            'on-kill-buffer))

(define-major-mode terminal-mode ()
    (:name "Terminal"
     :keymap *terminal-mode-keymap*)
  "Major mode for a live terminal buffer drawn by libghostty-vt.

This is semi-char input mode, the default: most keys go to the program,
while the prefixes in `*keymap-exceptions*' stay Lem's.  C-c C-c sends an
interrupt, C-c M-d switches to char mode, and C-c C-t enters copy mode."
  (initialize-terminal-buffer)
  (alexandria:when-let ((terminal (get-current-terminal)))
    (terminal:copy-mode-off terminal)))

(define-major-mode terminal-char-mode ()
    (:name "Terminal (Char)"
     :keymap *terminal-char-mode-keymap*)
  "Major mode for a live terminal buffer in char input mode.

Every key is sent to the program, including the prefixes that semi-char
mode reserves for Lem.  M-Return returns to semi-char mode."
  (initialize-terminal-buffer)
  (alexandria:when-let ((terminal (get-current-terminal)))
    (terminal:copy-mode-off terminal)))

(define-major-mode terminal-copy-mode ()
    (:name "Terminal (Copy)"
     :keymap *terminal-copy-mode-keymap*)
  "Major mode that freezes a terminal buffer so its text can be copied.

Rendering stops while this mode is active, so the shell cannot overwrite the
text under the selection.  Escape or C-c C-j returns to the live terminal."
  (initialize-terminal-buffer)
  (alexandria:when-let ((terminal (get-current-terminal)))
    (terminal:copy-mode-on terminal)))

(define-command terminal-input () ()
  "Send the keys that invoked this command to the terminal."
  (alexandria:when-let ((terminal (get-current-terminal)))
    (dolist (key (last-read-key-sequence))
      (terminal:send-key terminal key))))

(defun send-control-key (keyspec)
  "Send the single key named by KEYSPEC to the terminal."
  (alexandria:when-let ((terminal (get-current-terminal)))
    (dolist (key (parse-keyspec keyspec))
      (terminal:send-key terminal key))))

(define-command ghostty-terminal-send-interrupt () ()
  "Send C-c (SIGINT) to the terminal program."
  (send-control-key "C-c"))

(define-command ghostty-terminal-send-suspend () ()
  "Send C-z (SIGTSTP) to the terminal program."
  (send-control-key "C-z"))

(define-command ghostty-terminal-send-eof () ()
  "Send C-d (end of file) to the terminal program."
  (send-control-key "C-d"))

(define-command ghostty-terminal-send-quit () ()
  "Send C-\\ (SIGQUIT) to the terminal program."
  (send-control-key "C-\\"))

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

(defun key-same-p (a b)
  "True when keys A and B are the same key."
  (and (eq (key-ctrl a) (key-ctrl b))
       (eq (key-meta a) (key-meta b))
       (eq (key-super a) (key-super b))
       (eq (key-hyper a) (key-hyper b))
       (eq (key-shift a) (key-shift b))
       (equal (key-sym a) (key-sym b))))

(defvar *parsed-keymap-exceptions* nil
  "Cache of `*keymap-exceptions*' parsed into key lists.")

(defun parsed-keymap-exceptions ()
  (unless (eq (car *parsed-keymap-exceptions*) *keymap-exceptions*)
    (setf *parsed-keymap-exceptions*
          (cons *keymap-exceptions*
                (mapcar #'parse-keyspec *keymap-exceptions*))))
  (cdr *parsed-keymap-exceptions*))

(defun exception-key-sequence-p (keys exceptions)
  "True when KEYS starts with one of the EXCEPTIONS key lists."
  (some (lambda (prefix)
          (and (<= (length prefix) (length keys))
               (loop :for p :in prefix
                     :for k :in keys
                     :always (key-same-p p k))))
        exceptions))

(defun terminal-execute (command argument exceptions next)
  "Shared dispatch for the terminal input modes.

EXCEPTIONS is nil in char mode and the parsed `*keymap-exceptions*' in
semi-char mode.  NEXT calls the next most specific EXECUTE method."
  (cond
    ((member command *bypass-commands* :test #'typep)
     (funcall next))
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
    ;; Commands invoked programmatically, from M-x, or by the mouse have no
    ;; key sequence to send; let them run normally.
    ((null (last-read-key-sequence))
     (funcall next))
    ((exception-key-sequence-p (last-read-key-sequence) exceptions)
     (funcall next))
    (t
     (terminal-input))))

(defmethod execute :around ((mode terminal-mode) command argument)
  "Semi-char input mode dispatch.

This is an :AROUND method on purpose.  Several Lem commands -- notably
`delete-previous-char', which Backspace is bound to -- install their own
execute :around method and never call the next method.  An around method
on the terminal mode is more specific than those (the mode specializer is
compared before the command specializer), so it runs first and the key
reaches the shell instead of editing the read-only buffer.

Key sequences that start with a key from `*keymap-exceptions*' keep their
normal Lem meaning (C-x C-c quits, M-x opens the command loop); every
other key goes to the program.  Window management and prompts keep their
normal meaning under any binding."
  (terminal-execute command argument (parsed-keymap-exceptions)
                    (lambda () (call-next-method))))

(defmethod execute :around ((mode terminal-char-mode) command argument)
  "Char input mode dispatch: every key sequence goes to the program."
  (terminal-execute command argument nil
                    (lambda () (call-next-method))))

(defmethod lem-core:paste-using-mode ((mode terminal-mode) string)
  "Send pasted text to the program, using bracketed paste when enabled."
  (alexandria:when-let ((terminal (get-current-terminal)))
    (terminal:send-text terminal string)))

(defmethod lem-core:paste-using-mode ((mode terminal-char-mode) string)
  "Send pasted text to the program, using bracketed paste when enabled."
  (alexandria:when-let ((terminal (get-current-terminal)))
    (terminal:send-text terminal string)))
