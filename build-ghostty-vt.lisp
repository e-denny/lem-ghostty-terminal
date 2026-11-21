;;;; Build libghostty-vt and install it next to lem-ghostty-terminal.
;;;;
;;;; libghostty-vt is released separately from the Ghostty app.  This
;;;; script downloads the source and dependency tarballs for one vt-X.Y.Z
;;;; release, builds them with Zig, and copies the shared library to
;;;;   lib/<os>/<arch>/
;;;; next to this script, where ffi.lisp looks for it.
;;;;
;;;; Requirements: Zig 0.17.x (the version required by 1.0.x), curl and tar.
;;;;
;;;; Environment variables:
;;;;   LIBGHOSTTY_VT_VERSION  release to build (default "1.0.0")
;;;;   ZIG                   zig executable (default "zig")
;;;;   LEM_GHOSTTY_CACHE     download/build directory (default /tmp/libghostty-vt)
;;;;
;;;; Usage:
;;;;   sbcl --script ~/.config/lem/extensions/ghostty-terminal/build-ghostty-vt.lisp
;;;;
;;;; If libghostty-vt is already installed system-wide, or a build is
;;;; already present under lib/<os>/<arch>/, this script is not needed.

(require :asdf)
#+sbcl (require :sb-posix)
(require :uiop)

(defun extension-directory ()
  (uiop:pathname-directory-pathname *load-truename*))

(defparameter *release-base* "https://release.files.ghostty.org/libghostty-vt")
(defparameter *version* (or (uiop:getenv "LIBGHOSTTY_VT_VERSION") "1.0.0"))
(defparameter *zig* (or (uiop:getenv "ZIG") "zig"))
(defparameter *cache*
  (uiop:ensure-directory-pathname
   (or (uiop:getenv "LEM_GHOSTTY_CACHE") "/tmp/libghostty-vt")))

(defun architecture ()
  (or (uiop:architecture)
      (cond ((member :arm64 *features*) :arm64)
            ((member :aarch64 *features*) :arm64)
            ((member :x86-64 *features*) :x64)
            ((member :x86 *features*) :x86)
            (t (error "Cannot determine architecture from ~S" *features*)))))

(defun install-directory ()
  (merge-pathnames
   (format nil "~(lib/~A/~A/~)" (uiop:operating-system) (architecture))
   (extension-directory)))

(defun run (command &key (directory nil))
  (format t "~&~A~%" command)
  (finish-output)
  (uiop:run-program command :output t :error-output t :directory directory))

(defun download (name)
  "Download NAME under the cache unless it already exists."
  (let ((path (merge-pathnames name *cache*)))
    (unless (probe-file path)
      (ensure-directories-exist path)
      (run (list "curl" "-fL" "-o" (namestring path)
                 (format nil "~A/~A/~A" *release-base* *version* name))))
    path))

(defun extract (tarball)
  (run (list "tar" "-xzf" (namestring tarball)
             "-C" (namestring *cache*))))

(defun zig-version ()
  (string-trim '(#\Space #\Tab #\Newline #\Return)
               (uiop:run-program (list *zig* "version")
                                 :output :string
                                 :error-output :string
                                 :ignore-error-status t)))

(defun build ()
  (let* ((source-name (format nil "libghostty-vt-~A" *version*))
         (source (merge-pathnames (format nil "~A/" source-name) *cache*))
         (deps (merge-pathnames (format nil "~A-deps/" source-name) *cache*))
         (install (merge-pathnames (format nil "install-~A/" *version*) *cache*)))
    (ensure-directories-exist *cache*)
    (format t "Building libghostty-vt ~A with zig ~A~%"
            *version* (zig-version))
    (unless (probe-file (merge-pathnames "build.zig" source))
      (extract (download (format nil "~A.tar.gz" source-name))))
    (unless (probe-file deps)
      (extract (download (format nil "~A-deps.tar.gz" source-name))))
    (run (list *zig* "build"
               "--prefix" (namestring install)
               "--system" (namestring deps)
               "-Doptimize=ReleaseFast"
               "-Dcpu=baseline")
         :directory (namestring source))
    (let* ((libdir (merge-pathnames "lib/" install))
           (candidates (list (merge-pathnames "libghostty-vt.so.1.0.0" libdir)
                             (merge-pathnames "libghostty-vt.1.0.0.dylib" libdir)
                             (merge-pathnames "libghostty-vt.so" libdir)
                             (merge-pathnames "libghostty-vt.dylib" libdir)))
           (built (find-if #'probe-file candidates)))
      (unless built
        (error "No libghostty-vt shared library found under ~A" libdir))
      (ensure-directories-exist (install-directory))
      (let ((target (merge-pathnames
                     #+darwin "libghostty-vt.1.dylib"
                     #-darwin "libghostty-vt.so.1"
                     (install-directory))))
        ;; Copy the bytes explicitly: UIOP's COPY-FILE is a character
        ;; stream helper in some versions and would mangle the library.
        (let ((buffer (make-array 65536 :element-type '(unsigned-byte 8))))
          (with-open-file (in built :element-type '(unsigned-byte 8))
            (with-open-file (out target :direction :output
                                        :if-exists :supersede
                                        :element-type '(unsigned-byte 8))
              (loop :for n := (read-sequence buffer in)
                    :while (plusp n)
                    :do (write-sequence buffer out :end n)))))
        #+sbcl (sb-posix:chmod (namestring target) #o755)
        ;; ReleaseFast still carries symbols; stripping cuts the library
        ;; from ~12 MB to ~2 MB.  Best effort: macOS' strip has no
        ;; --strip-unneeded, and a failure here is harmless.
        (ignore-errors
          (uiop:run-program (list "strip" "--strip-unneeded" (namestring target))
                            :output :string :error-output :string))
        (format t "~&Installed ~A~%" target)
        (format t "lem-ghostty-terminal will load it from ~A~%"
                (install-directory))
        target))))

(build)
(uiop:quit 0)
