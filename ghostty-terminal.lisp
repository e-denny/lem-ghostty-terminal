(uiop:define-package :lem-ghostty-terminal
  (:use :cl :lem)
  (:import-from :lem-ghostty-terminal/terminal-mode
                :terminal-mode
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
                :ghostty-terminal-open-hyperlink
                :ghostty-terminal-next-hyperlink
                :ghostty-terminal-previous-hyperlink
                :create-terminal-with-command
                :ghostty-terminal-resize
                :ghostty-terminal-scroll-up
                :ghostty-terminal-scroll-down)
  (:import-from :lem-ghostty-terminal/ffi
                :library-available-p
                :*library-path*)
  (:import-from :lem-ghostty-terminal/terminal
                :ghostty-terminal-render-throttle-ms
                :ghostty-terminal-close-on-exit
                :ghostty-terminal-enable-osc52
                :ghostty-terminal-title-in-buffer-name
                :*terminal-term*)
  (:export :ghostty-terminal
           :terminal-mode
           :terminal-char-mode
           :terminal-copy-mode
           :*keymap-exceptions*
           :ghostty-terminal-copy-mode-on
           :ghostty-terminal-copy-mode-off
           :ghostty-terminal-send-interrupt
           :ghostty-terminal-send-suspend
           :ghostty-terminal-send-eof
           :ghostty-terminal-send-quit
           :ghostty-terminal-open-hyperlink
           :ghostty-terminal-next-hyperlink
           :ghostty-terminal-previous-hyperlink
           :create-terminal-with-command
           :ghostty-terminal-resize
           :ghostty-terminal-scroll-up
           :ghostty-terminal-scroll-down
           :setup
           :library-available-p
           :*library-path*
           :ghostty-terminal-render-throttle-ms
           :ghostty-terminal-close-on-exit
           :ghostty-terminal-enable-osc52
           :ghostty-terminal-title-in-buffer-name
           :*terminal-term*))
(in-package :lem-ghostty-terminal)

(defun setup (&key (key "C-c t"))
  "Convenience entry point for `init.lisp'.

Binds KEY globally to `ghostty-terminal' (pass NIL to skip binding).  Call
it after the system is loaded:

  (asdf:load-system :lem-ghostty-terminal)
  (lem-ghostty-terminal:setup :key \"C-c t\")"
  (when key
    (define-key *global-keymap* key 'ghostty-terminal))
  (values))
