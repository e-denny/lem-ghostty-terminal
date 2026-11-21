(uiop:define-package :lem-ghostty-terminal
  (:use :cl :lem)
  (:import-from :lem-ghostty-terminal/terminal-mode
                :ghostty-terminal
                :ghostty-terminal-copy-mode-on
                :ghostty-terminal-copy-mode-off
                :ghostty-terminal-resize
                :ghostty-terminal-scroll-up
                :ghostty-terminal-scroll-down)
  (:import-from :lem-ghostty-terminal/ffi
                :library-available-p
                :*library-path*)
  (:import-from :lem-ghostty-terminal/terminal
                :ghostty-terminal-render-throttle-ms
                :ghostty-terminal-close-on-exit)
  (:export :ghostty-terminal
           :ghostty-terminal-copy-mode-on
           :ghostty-terminal-copy-mode-off
           :ghostty-terminal-resize
           :ghostty-terminal-scroll-up
           :ghostty-terminal-scroll-down
           :setup
           :library-available-p
           :*library-path*
           :ghostty-terminal-render-throttle-ms
           :ghostty-terminal-close-on-exit))
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
