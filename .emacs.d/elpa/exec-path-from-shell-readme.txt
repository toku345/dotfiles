On OS X (and perhaps elsewhere) the $PATH environment variable and
`exec-path' used by a windowed Emacs instance will usually be the
system-wide default path, rather than that seen in a terminal
window.

This library allows the user to set Emacs' `exec-path' and $PATH
from the shell path, so that `shell-command', `compile' and the
like work as expected.

It also allows other environment variables to be retrieved from the
shell, so that Emacs will see the same values you get in a terminal.

Installation:

ELPA packages are available on Marmalade and Melpa. Alternatively, place
this file on a directory in your `load-path', and explicitly require it.

Usage:

    (require 'exec-path-from-shell) ;; if not using the ELPA package
    (exec-path-from-shell-initialize)

Customize `exec-path-from-shell-variables' to modify the list of
variables imported.

If you use your Emacs config on other platforms, you can instead
make initialization conditional as follows:

    (when (memq window-system '(mac ns))
      (exec-path-from-shell-initialize))

Alternatively, you can use `exec-path-from-shell-copy-envs' or
`exec-path-from-shell-copy-env' directly, e.g.

    (exec-path-from-shell-copy-env "PYTHONPATH")
