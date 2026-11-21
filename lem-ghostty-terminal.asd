(defsystem "lem-ghostty-terminal"
  :description "A libghostty-vt backed terminal emulator for Lem."
  :author "Lem contributors"
  :license "MIT"
  :depends-on ("lem/core"
               "cffi"
               ;; cffi-libffi is required for the two libghostty API calls
               ;; that pass or return structs by value: scrolling the
               ;; viewport and setting the UTF-8 text of a key event.
               "cffi-libffi")
  :serial t
  :components ((:file "ffi")
               (:file "terminal")
               (:file "terminal-mode")
               (:file "ghostty-terminal")))
