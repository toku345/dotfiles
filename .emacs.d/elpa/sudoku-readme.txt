;;; Commentary:

;; `sudoku-mode' is a major mode for solving sudoku puzzles. The rules are
;; simple: exactly one of each number in each of the nine rows, columns, and
;; subsquares. The puzzles are of four levels: easy, medium, hard, and evil.
;; sudoku-mode has a few nifty features, the most notable being that you can
;; download puzzles on the fly from websudoku.com (there are parsing functions
;; to take care of the html). The 200 included puzzles were generated using
;; the python-based generator from Thomas Hinkle's gnome-sudoku
;; (http://gnome-sudoku.sourceforge.net).
;;
;; I've added customization options, and you can also now customize via the
;; dropdown menu. If you really want to write in your .emacs file, though,
;; the three variables are `sudoku-level' ({"easy"|"medium"|"hard"|"evil"}),
;; `sudoku-puzzle-source' ({"built-in"|"web-site"|"custom"}),
;; `sudoku-download-method' ({"lynx"|"wget"|"w3"|"native-url-lib"}). But you
;; can do all this interactively. The main thing you really need to add is:
;;
;; (require 'sudoku)      (-- and be sure to put sudoku.elc in your load path)
;;
;; Note: Those who plan to use wget to download puzzles may also add:
;; (defvar sudoku-wget-process "<invocation pathname to your copy of wget>")
;;
;; To start puzzle solving (once the sudoku file is loaded), evaluate the
;; expression (sudoku) (say, in the *scratch* buffer), to set up and view
;; the special *sudoku* puzzle-solving buffer.
;;
;; UPDATE: Downloading files no longer requires lynx! Four options are now
;; offered: lynx, wget, the native url library in emacs >=22, and
;; w3 (which seems to be largely obsolete). This is set through the
;; `sudoku-download-method' variable, which is also available through the
;; configuration options. The default is to use "native-url-lib" if gnu emacs
;; is above version 22, and lynx otherwise. If anyone has any suggestions for
;; why another option should be the default, please let me know.
;;
;; The defaults are for `sudoku-level' to be "easy" and `sudoku-puzzle-source'
;; to be "built-in". But there are only about fifty puzzles of each level
;; included, so the chances of you repeating one are pretty good. You're
;; probably better off setting the puzzle-source to "web-site", if you're
;; online.
;;
;;
