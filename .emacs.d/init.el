;; -*- mode: Emacs-Lisp ; Coding: utf-8 -*-

;; load-path を追加する関数を定義
(defun add-to-load-path (&rest paths)
  (let (path)
    (dolist (path paths paths)
      (let ((default-directory
	     (expand-file-name (concat user-emacs-directory path))))
	(add-to-list 'load-path default-directory)
	(if (fboundp 'normal-top-level-add-subdirs-to-load-path)
	    (normal-top-level-add-subdirs-to-load-path))))))

;; 引数のディレクトリとそのサブディレクトリをload-path に追加
(add-to-load-path "elisp" "conf" "public_repos")

;; Mac だけに読み込ませる設定
(when (eq system-type 'darwin)
  ;; MacのEmacsでファイル名を正しく扱うための設定
  (require 'ucs-normalize)
  (setq file-name-coding-system 'utf-8-hfs)
  (setq locale-coding-system 'utf-8-hfs))

;;; -----------
;;; display
;;; -----------
;; tool-bar を非表示
(tool-bar-mode 0)
;; scroll-barを非表示
(scroll-bar-mode 0)

