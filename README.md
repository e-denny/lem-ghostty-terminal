# lem-ghostty-terminal

A terminal emulator for Lem backed by
[libghostty-vt](https://lib.ghostty.org/vt/), the standalone VT engine
extracted from Ghostty. It replaces the libvterm backend of `lem-terminal`
with a library that is faster, follows modern terminal behaviour more
closely (Kitty keyboard protocol, bracketed paste, synchronized output,
OSC 4/10/11 colours, true colour, grapheme clusters), and keeps scrollback
in native code instead of a Lisp ring buffer.

The extension is intentionally small: libghostty-vt only parses bytes and
exposes terminal state. The PTY comes from SBCL (`:pty`, `process-pty`),
cell drawing is done through CFFI into the Lem buffer, and keyboard input
is encoded by libghostty-vt's own key encoder so that application cursor
keys, modifyOtherKeys and Kitty keyboard flags are respected.

## Requirements

- **SBCL** with `sb-ext:run-program :pty` support (SBCL 2.6 or newer). The
  PTY code uses `sb-ext:run-program`, `sb-ext:process-pty`,
  `sb-unix:unix-read` and `sb-unix:unix-write`; other implementations are
  not supported yet.
- **libghostty-vt 1.0 or newer.** The C ABI is stable from 1.0.
- **cffi** and **cffi-libffi** (both in Quicklisp). `cffi-libffi` is needed
  for the two libghostty calls that pass structs by value (viewport
  scrolling and the UTF-8 text of a key event).
- **setsid(1)** on Linux/FreeBSD. SBCL allocates the pty but does not make
  it the child's controlling terminal; running the shell under
  `setsid -c` gives it a session and a controlling terminal so job
  control and Ctrl-C work. Without `setsid -c` the terminal still works,
  but the shell prints "no job control in this shell" and foreground
  signals are unreliable.

The repository does not ship the native library. Build it as described
below and place it at `lib/linux/x64/libghostty-vt.so.1` (or the matching
`lib/<os>/<arch>/` directory), install libghostty-vt system-wide, or point
`LEM_GHOSTTY_VT_LIBRARY` at an existing build.

## Building libghostty-vt

libghostty-vt is written in Zig and released separately from Ghostty
(`vt-X.Y.Z` tags). To build the version this package was tested with:

```sh
curl -LO https://release.files.ghostty.org/libghostty-vt/1.0.0/libghostty-vt-1.0.0.tar.gz
curl -LO https://release.files.ghostty.org/libghostty-vt/1.0.0/libghostty-vt-1.0.0-deps.tar.gz
tar -xzf libghostty-vt-1.0.0.tar.gz
tar -xzf libghostty-vt-1.0.0-deps.tar.gz

# Zig 0.17.x is required by 1.0.0; download the release for your platform
# from https://ziglang.org/download/

cd libghostty-vt-1.0.0
zig build --prefix /tmp/ghostty-install \
          --system ../libghostty-vt-1.0.0-deps \
          -Doptimize=ReleaseFast -Dcpu=baseline
```

Then copy `lib/libghostty-vt.so.1.0.0` (or `.dylib`) to

```
lib/<os>/<arch>/libghostty-vt.so.1
```

or set `LEM_GHOSTTY_VT_LIBRARY` to its absolute path. `build-ghostty-vt.lisp`
automates the download/build/copy when `zig`, `curl` and `tar` are present
(see the script header for the environment variables it honours).

## Loading it from init.lisp

This tree is a user extension: it lives in
`~/.config/lem/extensions/ghostty-terminal/` and is loaded from
`~/.config/lem/init.lisp`, not compiled into Lem.  The relevant part of
`init.lisp` is:

```lisp
;;; libghostty-vt backed terminal.
;;; C-c t opens it from a normal buffer.  Inside the terminal C-c is sent
;;; to the program, so use M-x ghostty-terminal or the same command from
;;; another window to open another one.
(pushnew (merge-pathnames "extensions/ghostty-terminal/" (lem-home))
         asdf:*central-registry*
         :test #'equal)
(asdf:load-system :lem-ghostty-terminal)
(lem-ghostty-terminal:setup :key "C-c t")
```

`ASDF` finds `lem-ghostty-terminal.asd` through the pushed directory, and
the system's dependencies (`cffi`, `cffi-libffi`) come from the Quicklisp
distribution that Lem itself uses.  The native library is resolved
relative to the ASD, so the vendored `lib/` directory keeps working from
the new location.

## Using it

- `M-x ghostty-terminal` opens a shell in the current buffer's directory.
  With a prefix argument it always creates a new terminal buffer.
- Typing goes to the program. Application cursor keys, Kitty keyboard
  protocol, bracketed paste, `modifyOtherKeys`, Ctrl-C/Ctrl-X/Ctrl-Z and
  the other control keys are passed through rather than interpreted by
  Lem.
- `PageUp`/`PageDown`, `C-v`/`M-v` and the **mouse wheel** scroll the
  **terminal viewport** through libghostty-vt's native scrollback rather
  than moving point through an inserted copy of the history. The wheel uses
  Lem's `*scroll-speed*` (three rows per notch by default). Typing snaps the
  viewport back to the live screen.
- `M-[` enters copy mode: rendering stops, the buffer is frozen, normal
  Lem movement and kill-ring commands can be used, and `Escape` returns to
  the live terminal. `M-x ghostty-terminal-copy-mode-on`/`-off` do the
  same.
- The terminal grid follows the window size automatically.
- When the child process exits, for example when you type `exit` in the
  shell, the terminal buffer is deleted and its window switches back to the
  previous buffer, the way a terminal emulator closes its window.  Set
  `ghostty-terminal-close-on-exit` to NIL to keep the final screen instead:

  ```lisp
  (setf (variable-value 'lem-ghostty-terminal:ghostty-terminal-close-on-exit
                        :global)
        nil)
  ```

  Lem always keeps at least one buffer, so the last buffer is never deleted.
- The buffer's default foreground and background stay Lem's theme colours;
  ANSI, 256-colour and 24-bit colours from the program are drawn as
  requested. This keeps the terminal from becoming a hard black rectangle
  in a light theme.

### Limitations

- No mouse reporting, Kittyp graphics, hyperlinks, notifications or
  clipboard integration yet. The clipboard works through Lem's normal
  paste path (`paste-using-mode`), which honours bracketed paste.
- No incremental rendering of the non-ASCII width cache beyond what
  libghostty reports; the renderer reads the style of every cell in a
  dirty row.
- SBCL only, for the PTY layer described above.
- The process is not suspended with Ctrl-Z at the editor level; Ctrl-Z is
  sent to the program, which is what a terminal should do.

## Architecture

```
~/.config/lem/extensions/ghostty-terminal/
├── lem-ghostty-terminal.asd  ASDF system definition
├── ffi.lisp            CFFI bindings, structs, effect dispatchers
├── terminal.lisp       PTY, I/O thread, render timer, renderer, input
├── terminal-mode.lisp  major modes, keymaps, commands, hooks
├── ghostty-terminal.lisp  user-facing package and SETUP
├── build-ghostty-vt.lisp  optional libghostty-vt build helper
└── lib/<os>/<arch>/    optional vendored libghostty-vt
```

- **Reading.** A dedicated thread waits on the pty master with a 100 ms
  timeout, reads raw octets and hands them to
  `ghostty_terminal_vt_write`. libghostty-vt parses on that thread; a
  pending flag tells the editor thread to render.
- **Rendering.** A one-shot Lem timer (default 33 ms) calls
  `ghostty_render_state_update`, walks only the rows libghostty marks
  dirty, reads each cell's style and UTF-8 graphemes, and writes the row
  directly into the buffer's `line` object. A per-terminal attribute cache
  keyed by packed colour/decoration bits keeps `make-attribute` off the
  hot path.
- **Replying.** Replies the VT engine generates (DSR, DA, XTGETTCAP,
  mode reports) arrive through the `WRITE_PTY` effect callback and are
  written straight back to the pty master. There is exactly one such
  callback per terminal, dispatched by the terminal id stored in the
  callback userdata.
- **Input.** Before each key, the encoder is resynchronised from the
  terminal (`ghostty_key_encoder_set_from_terminal`), so mode changes made
  by the program take effect immediately. The resulting bytes go to the
  pty master. Paste goes through the terminal's own bracketed-paste state.
- **Threading.** One mutex serialises every libghostty-vt call. The parse
  thread holds it only for `vt_write`; the editor thread holds it while
  rendering, scrolling, resizing and encoding keys. The render timer has
  its own lock so a slow frame cannot deadlock the parse thread.
