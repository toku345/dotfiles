;; -*- mode: Emacs-Lisp ; Coding: utf-8 -*-
(require 'cl)

(fset 'yes-or-no-p 'y-or-n-p)
(setq inhibit-startup-screen t)

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
(add-to-load-path "elisp" "conf" "public_repos" "github" "elpa")

;; Mac だけに読み込ませる設定
;; (when (eq system-type 'gnu/linux)
  ;; (setq file-name-coding-system 'utf-8-unix)
  ;; (set locale-coding-system 'utf-8-unix))
(setq file-name-coding-system 'utf-8)
(setq locale-coding-system 'utf-8)


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

;;; -----------
;;; key-binds
;;; -----------
;; C-mにnewline-and-indentを割り当てる。初期値はnew-line
(global-set-key (kbd "C-m") 'newline-and-indent)

;;
(define-key global-map (kbd "C-c l") 'toggle-truncate-lines)

;;
(define-key global-map (kbd "C-t") 'other-window)

;; 入力されるキーシーケンスを置き換える
;; ?\C-?はDELのキーシーケンス
(keyboard-translate ?\C-h ?\C-?)
;;
(define-key global-map (kbd "C-x ?") 'help-command)

;; (if (eq window-system 'mac)
;;     (setq mac-command-modifier 'super)
;;     (setq mac-option-modifier 'meta))

;; ====================================================================
;;; package.el
;; (install-elisp "http://bit.ly/pkg-el23") (Emacs24からはinstall不要)
(when (require 'package nil t)
  ;; パッケージリポジトリにMarmaladeと開発者運営のELPAを追加
  (add-to-list 'package-archives '("marmalade" . "http://marmalade-repo.org/packages/"))
  (add-to-list 'package-archives '("ELPA" . "http://tromey.com/elpa/"))
  (add-to-list 'package-archives '("melpa" . "http://melpa.milkbox.net/packages/"))
  (setq url-http-attempt-keepalives nil) ;To fix MELPA problem.
  ;;  (package-refresh-contents)
  (package-initialize))
;; ====================================================================

;; ----------
;; path
;; ----------
;; (exec-path-from-shell-initialize)
;; (defun set-exec-path-from-shel-PATH ()
;;   "Set up Emacs' `exec-path' and PATH environment variable to match that used by the user's shell.
;;    This is particularly useful under Mac OSX, where GUI apps are not started from a shell."
;;   (interactive)
;;   (let ((path-from-shell (replace-regexp-in-string "[ \t\n]*$" "" (shell-command-to-string "$SHELL --login -i -c 'echo $PATH'"))))
;;     (setenv "PATH" path-from-shell)
;;     (setq exec-path (split-string path-from-shell path-separator))))
;; (set-exec-path-from-shel-PATH)

;;; exec-path-form-shell
;; (require 'exec-path-from-shell)
(when (memq window-system '(mac ns))
  (exec-path-from-shell-initialize))
;; (setq exec-path (append '("/Users/fumitaka/.anyenv/envs/rbenv/shims:" exec-path)))

;; (add-to-list 'exec-path "/opt/local/bin")
;; (add-to-list 'exec-path "/usr/local/bin")
;; (add-to-list 'exec-path "~/bin")


;; ------------
;; language
;; ------------
;; ;; (set-language-environment "Japanese")
;; ;; (prefer-coding-system 'utf-8-unix)
;; ;; (setq locale-coding-system 'utf-8-unix)
;; (set-language-environment 'utf-8)
;; (set-default-coding-systems 'utf-8)

;; Mac OS X
(when (eq system-type 'darwin)
  (require 'ucs-normalize)
  (set-file-name-coding-system 'utf-8-hfs)
  (setq locale-coding-system 'utf-8-hfs))

;; Windows
(when (eq window-system 'w32)
  (set-file-name-coding-system 'cp932)
  (setq locale-coding-system 'cp932))

;; ------------
;; frame
;; ------------
;; disp column No
(column-number-mode t)
;; disp file size
(size-indication-mode t)
;; disp clock
;; (setq display-time-day-and-date t)
;; (setq display-time-24hr-format t)
(display-time-mode t)
;;
;; (display-battery-mode t)

;; リージョン内の行数と文字数をモードラインに表示する(範囲指定時のみ)
;; http://d.hatena.ne.jp/sonota88/20110224/1298557375
(defun count-lines-and-chars ()
  (if mark-active
      (format "%d lines,%d chars "
              (count-lines (region-beginning) (region-end))
              (- (region-end) (region-beginning)))
    ;; これだとエコーエリアがチラつく
    ;; (count-lines-region (region-beginning) (region-end))
    ""))

(add-to-list 'default-mode-line-format
             '(:eval (count-lines-and-chars)))

;; タイトルバーにファイルのフルパスを表示
(setq frame-title-format "%f")

;; 行番号を常に表示する
;; (global-linum-mode t)

;; ----------------
;; indent
;; ----------------
(setq-default tab-width 4)

;; インデントにタブ文字を使用しない
(setq-default indent-tabs-mode nil)

;; ----------------
;; face
;; ----------------
;; リージョンの背景色を変更
(set-face-background 'region "darkgreen")

;;; install color-theme
;; http://download.savannah.gnu.org/releases/color-theme/color-theme-6.6.0.tar.gz
(when (require 'color-theme nil t)
  ;; テーマを読み込むための設定
  (color-theme-initialize)
  ;; テーマの変更
  (color-theme-hober))
;; (color-theme-heroku)

;; ----------------
;; font
;; ----------------
(set-face-attribute 'default nil
                    :family "Ricty"
                    :height 120)
(set-fontset-font
 nil 'japanese-jisx0208
 (font-spec :family "Ricty"))

(when (eq window-system 'ns)
  ;; asciiフォントをMenloに
  (set-face-attribute 'default nil
                      :family "Menlo"
                      :height 110)
  ;; 日本語フォントをヒラギノ明朝に
  (set-fontset-font
   nil 'japanese-jisx0208
   (font-spec :family "Hiragino Mincho Pro"))
  ;; フォントの横幅を調整する
  (setq face-font-rescale-alist
        '((".*Menlo.*" . 1.0)
          (".*Hiragino_Mincho_Pro.*" . 1.2)
          ("-cdac$" . 1.3))))

(when (eq system-type 'windows-nt)
  (set-face-attribute 'default nil
                      :family "Consolas"
                      :height 120)
  (set-fontset-font
   nil 'japanese-jisx0208
   (font-spec :family "メイリオ"))
  (setq face-font-rescale-alist
        '((".*Consolas.*" . 1.0)
          (".*メイリオ.*" . 1.15)
          ("-cdac$" .  1.3))))

;; ----------
;; hi-light
;; ----------
;; 現在行のハイライト
(defface my-hl-line-face
  ;; 背景がdarkなら背景色を紺に
  '((((class color) (background dark))
     (:background "NavyBlue" t))
    ;; 背景がlightなら背景色を緑に
    (((class color) (background light))
     (:background "LightGoldenrodYellow" t))
    (t (:bold t)))
  "hl-line's my face")
(setq hl-line-face 'my-hl-line-face)
(global-hl-line-mode t)

;; paren-mode : 対応する括弧を強調してする
(setq show-paren-delay 0)
(show-paren-mode t)
;; parenのスタイル : expressionは括弧内も強調表示
(setq show-paren-style 'expression)
;; フェイスを変更する
(set-face-background 'show-paren-match-face nil)
(set-face-underline-p 'show-paren-match-face "yellow")

;; バックアップとオートセーブファイルを~/.emacs.d/backups/へ集める
(add-to-list 'backup-directory-alist
             (cons "." "~/.emacs.d/backups/"))
(setq auto-save-file-name-transforms
      `((".*" ,(expand-file-name "~/.emacs.d/backups/") t)))

;; オートセーブファイル作成までの時間
(setq auto-save-timeout 15)
;; オートセーブファイル作成までのタイプ間隔
(setq auto-save-interval 60)

;; ls -> gls
(let ((gls "/usr/local/bin/gls"))
  (if (file-exists-p gls) (setq insert-directory-program gls)))

;; -----------
;; emacslisp
;; -----------
;; auto-installの設定
(when (require 'auto-install nil t)
  (setq auto-install-directory "~/.emacs.d/elisp/")
  (auto-install-update-emacswiki-package-name t)
  (auto-install-compatibility-setup)
  (setq ediff-window-setup-function 'ediff-setup-windows-plain))

;;; redo+
;; (install-elisp "http://www.emacswiki.org/emacs/download/redo+.el")
;; (when (require 'redo+ nil t)
;;   (global-set-key (kbd "C-'") 'redo))

;;; undo-tree
(require 'undo-tree)
(global-undo-tree-mode t)
(global-set-key (kbd "C-'") 'undo-tree-redo)

;;; anything
;; (auto-install-batch "anything")
(when (require 'anything nil t)
  (setq
   anything-idle-delay 0.3
   anything-input-idle-delay 0.2
   anything-candidate-nuber-limit 100
   anything-quick-update t
   anything-enable-shortcuts 'alphabet)

  (when (require 'anything-config nil t)
    ;; root権限でアクションを実行するときのコマンド
    (setq anything-su-or-sudo "sudo"))

  (require 'anything-match-plugin nil t)

  (when (and (executable-find "cmigemo")
             (require 'migemo nil t))
    (require 'anything-migemo nil t))

  (when (require 'anything-complete nil t)
    ;; lispシンボルの補完候補の再検索時間
    (anything-lisp-complete-symbol-set-timer 150))

  (require 'anything-show-completion nil t)

  (when (require 'auto-install nil t)
    (require 'anything-auto-install nil t))

  (when (require 'descbinds-anything nil t)
    ;; describe-bindingsをAnythingに置き換える
    (descbinds-anything-install)))

;;; anything-show-kill-ring
;; M-yにanything-show-kill-ringを割り当てる
(define-key global-map (kbd "M-y") 'anything-show-kill-ring)

;;; anything-c-moccur (要color-moccur.el)
(when (require 'anything-c-moccur nil t)
  (setq
   anything-c-moccur-anything-idle-delay 0.1
   anything-c-moccur-highlight-info-line-flag t
   anything-c-moccur-enable-auto-look-flag t
   anything-c-moccur-enable-initial-pattern t)
  ;; C-M-oにanything-c-moccur-occur-by-moccurを割り当てる
  (global-set-key (kbd "C-M-o") 'anything-c-moccur-occur-by-moccur))

;; anything-rdefs
;; (require 'anything-rdefs)

;; (setq ar:command "/Users/fumitaka/.rvm/gems/ruby-2.1.0/bin/rdefs")
;; (add-hook 'ruby-mode-hook
;;           (lambda ()
;;             (define-key ruby-mode-map (kbd "C-@") 'anything-rdefs)))

;; color-moccur
(when (require 'color-moccur nil t)
  ;; M-oにoccur-by-moccurを割り当て
  (define-key global-map (kbd "M-o") 'occur-by-moccur)
  ;; スペース区切りでAND検索
  (setq moccur-split-word t)
  ;; ディレクトリ検索のとき除外するファイル
  (add-to-list 'dmoccur-exclusion-mask "¥¥.DS_Store")
  (add-to-list 'dmoccur-exclusion-mask "^#.+#$")
  ;; Migemoを利用できる環境であればMigemoを使う
  (when (and (executable-find "cmigemo")
             (require 'migemo nil t))
    (setq moccur-use-migemo t)))

;;; moccur-edit
(require 'moccur-edit)

;;; auto-complete
;; (require 'auto-complete) ;; << auto-complete-configを読み込むと一緒に読み込んでくれるらしい。。。
(when (require 'auto-complete-config nil t)
  (add-to-list 'ac-dictionary-directories "~/.emacs.d/elisp/ac-dict")
  (define-key ac-mode-map (kbd "M-TAB") 'auto-complete)
  (define-key ac-complete-mode-map (kbd "C-n") 'ac-next)
  (define-key ac-complete-mode-map (kbd "C-p") 'ac-previous)
  (global-auto-complete-mode t)
  (ac-config-default))

;;; elscreen
;; (when (<= emacs-major-version 23)
;;   (when (require 'elscreen nil t)
;;     ;; C-z C-zをタイプした場合にデフォルトのC-zを利用する
;;     (if window-system
;;         (define-key elscreen-map (kbd "C-z") 'iconify-deicnify-frame)
;;       (define-key elscreen-map (kbd "C-z") 'suspend-emacs)))))

;; (when (>= emacs-major-version 24)
;;   (elscreen-start))


;; (when (require 'elscreen-start nil t)
;;   (if window-system
;;       (define-key elscreen-map (kbd "C-z") 'iconify-or-deiconify-frame)
;;     (define-key elscreen-map (kbd "C-z") 'suspend-emacs)))
(elscreen-start)

;; ;; ;;; tabbar
;; ;; (tabbar-mode 1)
;; ;; ;; グループ化しない
;; ;; (setq tabbar-buffer-groups-function nil)
;; ;; ;; タブ上でマウスホイール操作を無効化
;; ;; (setq tabbar-mwheel-mode -1)
;; ;; ;; ウィンドウからはみ出たタブを省略
;; ;; (setq tabbar-auto-scroll-flag nil)
;; ;; ;; 左に表示されるボタンを無効化
;; ;; (dolist (btn '(tabbar-buffer-home-button
;; ;;                tabbar-scroll-left-button
;; ;;                tabbar-scroll-right-button))
;; ;;   (set btn (cons (cons "" nil)
;; ;;                  (cons "" nil))))
;; ;; ;; タブ間隔
;; ;; (setq tabbar-separator '(1.5))
;; ;; ;; 外観変更
;; ;; (set-face-attribute
;; ;;  'tabbar-default nil
;; ;;  :family (face-attribute 'default :family)
;; ;;  :background (face-attribute 'mode-line-inactive :background)
;; ;;  :height 0.9)
;; ;; (set-face-attribute
;; ;;  'tabbar-unselected nil
;; ;;  :background (face-attribute 'mode-line-inactive :background)
;; ;;  :foreground (face-attribute 'mode-line-inactive :foreground)
;; ;;  :box nil)
;; ;; (set-face-attribute
;; ;;  'tabbar-selected nil
;; ;;  :background (face-attribute 'mode-line :background)
;; ;;  :foreground (face-attribute 'mode-line :foreground)
;; ;;  :box nil)
;; ;; (global-set-key (kbd "M-p") 'tabbar-backward-tab)
;; ;; (global-set-key (kbd "M-n") 'tabbar-forward-tab)
;; ;; ;; タブに表示させるバッファ
;; ;; (defvar my-tabbar-displayed-buffers
;; ;;   '("*scratch*" "*Messages*" "*Backtrace*" "*Colors*" "*Faces*" "*vc-")
;; ;;   "*Regexps matches buffer names always included tabs.")
;; ;; (defun my-tabbar-buffer-list ()
;; ;;   "Return the list of buffers to show in tabs.
;; ;; Exclude buffers whose name starts with a space or an asterisk.
;; ;; The current buffer and buffers matches `my-tabbar-displayed-buffers`
;; ;; are always includes."
;; ;;   (let* ((hide (list ?\ ?\*))
;; ;;          (re (regexp-opt my-tabbar-displayed-buffers))
;; ;;          (cur-buf (current-buffer))
;; ;;          (tabs (delq nil
;; ;;                      (mapcar (lambda (buf)
;; ;;                                (let ((name (buffer-name buf)))
;; ;;                                  (when (or (string-match re name)
;; ;;                                            (not (memq (aref name 0) hides)))
;; ;;                                    buf)))
;; ;;                              (buffer-list)))))
;; ;;     ;; Always include the current buffer.
;; ;;     (if (memq cur-buf tabs)
;; ;;         tabs
;; ;;       (cons cur-buf tabs))))
;; ;; (setq tabbar-buffer-list-function 'my-tabbar-buffer-list)
;; ;; ;; Hide for special buffers
;; ;; (when (require 'tabbar nil t)
;; ;;   (setq tabbar-buffer-groups-function
;; ;;         (lambda () (list "All Buffers")))
;; ;;   (setq tabbar-buffer-list-function
;; ;;         (lambda ()
;; ;;           (remove-if
;; ;;            (lambda (buffer)
;; ;;              (find (aref (buffer-name buffer) 0) " *"))
;; ;;            (buffer-list))))
;; ;;   (tabbar-mode))

;; ibuffer
(global-set-key (kbd "C-x C-b") 'ibuffer)

;;; cua-mode
(cua-mode t)
(setq cua-enable-cua-keys nil)          ;CUA キーバインドを無効にする

;;; summarye
;; M-x install-elisp-from-emacs summarye.el
(require 'summarye)
(define-key global-map (kbd "C-o") 'se/make-summary-buffer)

;;; gtags
(require 'gtags nil t)
;; ;; gtags-mode のキーバインドを有効化する
;; (setq gtags-suggested-key-mapping t)
(add-hook 'c-mode-common-hook 'gtags-mode)
(add-hook 'c++-mode-hook 'gtags-mode)
;; (add-hook 'java-mode-hook 'gtags-mode)
;; (add-hook 'malabar-mode-hook 'gtags-mode)
;; 相対パス表示
(setq gtags-path-style 'relative)
;; ジャンプ先を読み取り専用バッファにする
(setq view-read-only t)                 ; 読み込み専用バッファを自動的にview-modeにする
(setq gtags-read-only t)                ; 上と組み合わせることで、タグジャンプ先をview-modeにする

;; 一覧表示関数
(defun gtags-parse-file2 ()
  (interactive)
  (if (gtags-get-rootpath)
      (let*
          ((root (gtags-get-rootpath))
           (path (buffer-file-name))
           (gtags-path-style 'root)
           (gtags-rootdir root))
        (if (string-match (regexp-quote root) path)
            (gtags-goto-tag
             (replace-match "" t nil path)
             "f" nil)
          ;; delegate to gtags-parse-file
          (gtags-parse-file)))
    ;; delegate to gtags-parse-file
    (gtags-parse-file)))

;; ;;; sudo-ext
(server-start)
(require 'sudo-ext)

;;; open-junk-file
;; 試行錯誤用ファイルを開くための設定
(require 'open-junk-file)
;; C-x C-z で試行錯誤ファイルを開く
(global-set-key (kbd "C-x C-z") 'open-junk-file)

;;; paredit
;; 括弧の対応を保持して編集する設定
(require 'paredit)
(add-hook 'emacs-lisp-mode-hook 'enable-paredit-mode)
(add-hook 'lisp-interaction-mode-hook 'enable-paredit-mode)
(add-hook 'lisp-mode-hook 'enable-paredit-mode)
(add-hook 'ielm-mode-hook 'enable-paredit-mode)
(add-hook 'scheme-mode-hook 'enable-paredit-mode)

;;; auto-async-byte-compile
(require 'auto-async-byte-compile)
;; 自動バイトコンパイルを無効にするファイル名の正規表現
(setq auto-async-byte-compile-exclude-files-regexp "/junk/")
(add-hook 'emacs-lisp-mode-hook 'enable-auto-async-byte-compile-mode)
(add-hook 'emacs-lisp-mode-hook 'turn-on-eldoc-mode)
(add-hook 'lisp-interaction-mode-hook 'turn-on-eldoc-mode)
(add-hook 'ielm-mode-hook 'turn-on-eldoc-mode)
;;(setq eldoc-idle-delay 0.2)				; すぐに表示したい  ;; ※上で設定済み
(setq eldoc-minor-mode-string "")		; モードラインにElDocと表示しない

;; find-function をキー割当てする
(find-function-setup-keys)

;; edit-server.el(chormeのエクステンション)
(require 'edit-server)
(edit-server-start)
(setq edit-server-new-frame nil)

;; summarye.el
(require 'summarye)

;; ;; yasnippet
;; (require 'yasnippet)
;; (yas-global-mode 1)

;; org-mode
(require 'org)
;; (defun org-insert-upheading (arg)
;;   "１レベル上の見出しを入力する。"
;;   (interactive "P")
;;   (org-insert-heading arg)
;;   (cond ((org-on-heading-p) (org-do-promoto))
;;         ((org-at-item-p) (org-indent-item -1))))
;; (defun org-insert-heading-dwim (arg)
;;   "現在と同じレベルの見出しを入力する。
;; C-uをつけると１レベル上、C-u C-uをつけると１レベル下の見出しを入力する。"
;;   (interactive "p")
;;   (case arg
;;     (4  (org-insert-subheading nil))    ; C-u
;;     (16 (org-insert-upheading  nil))    ; C-u C-u
;;     (t  (org-insert-heading    nil))))
;; (define-key org-mode-map (kbd "C-<return>") 'org-insert-heading-dwim)
;; ;; (define-key global-map (kbd "C-<return>") 'org-insert-heading-dwim)

;; ;; org-remember
;; (org-remember-insinuate)                ; org-rememberの初期化
;; ;; メモを格納するorgファイルの設定
;; (setq org-directory "~/memo/")
;; (setq org-default-notes-file (expand-file-name "memo.org" org-directory))
;; ;; テンプレートの設定
;; (setq org-remember-templates
;;       '(("Note" ?n "** %? \n   %i\n   %t" nil "inbox")
;;         ("Todo" ?t "** TODO %?\n   %i\n   %a\n   %t" nil "Inbox")))

;; fold-dwim
(require 'fold-dwim)
;; hideshow.el
(require 'hideshow)

;; hideif.el
(require 'hideif)
(add-hook 'c-mode-common-hook 'hide-ifdef-mode)

;; ;; igrep
;; (require 'igrep)
;; ;; lgrepに-0u8オプションをつけると出力がUTF-8になる
;; (igrep-define lgrep (igrep-use-zgrep nil) (igrep-regex-option "-Ou8"))
;; (igrep-find-define lgrep (igrep-use-zgrep nil) (igrep-regex-option "-Ou8"))

;; grep-a-lot
(require 'grep-a-lot)
(grep-a-lot-setup-keys)
(grep-a-lot-advise igrep)

;; grep-edit
(require 'grep-edit)

;; uniquify
(require 'uniquify)
;; filename<dir> 形式のバッファ名にする
(setq uniquify-buffer-name-style 'post-forward-angle-brackets)
;; *で囲まれたバッファ名は対象外にする
(setq uniquify-ignore-buffers-re "*[^*]+*")

;; tempbuf
(require 'tempbuf)
;; ファイルを開いたら自動的にtempbufを有効にする
;; (add-hook 'find-file-hooks 'turn-on-tempbuf-mode)
;; diredバッファに対してtempbufを有効にする
(add-hook 'dired-mode-hook 'turn-on-tempbuf-mode)

;; ipa
(require 'ipa)

;; smooth-scroll
(require 'smooth-scroll)
(smooth-scroll-mode t)

;; whitespace.el
(require 'whitespace)
(global-whitespace-mode 1)

(setq whitespace-space-regexp "\\(\x3000+\\|^ +\\| +$\\)")

(set-face-foreground 'whitespace-newline "gray30")
(set-face-foreground 'whitespace-tab     "gray30")
(set-face-foreground 'whitespace-space   "gray30")

(dolist (d '((space-mark ?\ )))
  (setq whitespace-display-mappings
        (delete-if
         '(lambda (e) (and (eq (car d) (car e))
                           (eq (cadr d) (cadr e))))
         whitespace-display-mappings)))

(dolist (e '((space-mark ?\x3000 [?\■])))
  (add-to-list 'whitespace-display-mappings e))

(dolist (d '(lines indentation empty
                   space-before-tab space-after-tab))
  (setq whitespace-style (delq d whitespace-style)))

;; emacs-mozc
(require 'mozc)
;; (set-language-environment "japanese")
(setq default-input-method "japanese-mozc")
;; (setq mozc-candidate-style 'overlay)
(setq mozc-candidate-style 'echo-area)
(global-set-key (kbd "s-SPC") 'toggle-input-method)

;; auto-highlight-symbol
(require 'auto-highlight-symbol)
(global-auto-highlight-symbol-mode t)

;; ag
(setq default-process-coding-system 'utf-8-unix) ; ag 検索結果のエンコーディング
(require 'ag)
(setq ag-highlight-search t)
(setq ag-reuse-buffers t)

;; wgrep
(add-hook 'ag-mode-hook '(lambda ()
                           (require 'wgrep-ag)
                           (setq wgrep-auto-save-buffer t)
                           (setq wgrep-enable-key "r")
                           (wgrep-ag-setup)))

;; ------
;; hook
;; ------
;; ファイル名が #! から始まる場合、+xをつけて保存する
(add-hook 'after-save-hook
          'executable-make-buffer-file-executable-if-script-p)

;;; mmm-mode
;; (require 'mmm-mode)                     ; 起動時にすべてロードさせたい場合
(require 'mmm-auto)                     ; autoloadさせたい場合

;; (mmm-add-mode-ext-class 'html-erb-mode "\\.html\\.erb\\'" 'erb)
;; (mmm-add-mode-ext-class 'html-erb-mode "\\.jst\\.ejs\\'" 'ejs)
;; (mmm-add-mode-ext-class 'html-mode "\\.ejs\\'" 'html-js)
;; (mmm-add-mode-ext-class 'html-erb-mode nil 'html-js)
;; (mmm-add-mode-ext-class 'html-erb-mode nil 'html-css)
(mmm-add-mode-ext-class 'html-mode "\\.php\\'" 'html-php)
(mmm-add-mode-ext-class 'html-mode nil 'mason)

;; (add-to-list 'auto-mode-alist '("\\.html\\.erb\\'" . html-erb-mode))
;; (add-to-list 'auto-mode-alist '("\\.jst\\.ejs\\'" . html-erb-mode))
;; (add-to-list 'auto-mode-alist '("\\.ejs\\'" . html-ejs))

;; mmm-modeの使用タイミング
; t:常に使用, nil:自動では使用しない場合,   'maybe/auto(t,nil以外):自動で判別
(setq mmm-global-mode 'auto)

;;; Common Lisp
(modify-coding-system-alist 'process "clisp" '(utf-8 . utf-8))

(setq inferior-lisp-program "clisp")

(defun clisp-other-window ()
  "Run clisp on other window"
  (interactive)
  (switch-to-buffer-other-window
   (get-buffer-create "*clisp*"))
  (run-lisp inferior-lisp-program))

(define-key lisp-mode-map "\C-cs" 'clisp-other-window)
;; (autoload global-map "\C-cc" 'clisp-other-window)


;;; gauche
(modify-coding-system-alist 'process "gosh" '(utf-8 . utf-8))

(setq scheme-program-name "gosh -i")
(autoload 'scheme-mode "cmuscheme" "Major mode for Scheme." t)
(autoload 'run-scheme  "cmuscheme" "Run an inferior Scheme process." t)

(defun scheme-other-window ()
  "Run scheme on other window"
  (interactive)
  (switch-to-buffer-other-window
   (get-buffer-create "*scheme*"))
  (run-scheme scheme-program-name))

(define-key global-map "\C-cs" 'scheme-other-window)

(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(safe-local-variable-values (quote ((Coding . utf-8)))))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )

;; インデントの定義
(put 'and-let* 'scheme-indent-function 1)
(put 'begin0 'scheme-indent-function 0)
(put 'call-with-client-socket 'scheme-indent-function 1)
(put 'call-with-input-conversion 'scheme-indent-function 1)
(put 'call-with-input-file 'scheme-indent-function 1)
(put 'call-with-input-process 'scheme-indent-function 1)
(put 'call-with-input-string 'scheme-indent-function 1)
(put 'call-with-iterator 'scheme-indent-function 1)
(put 'call-with-output-conversion 'scheme-indent-function 1)
(put 'call-with-output-file 'scheme-indent-function 1)
(put 'call-with-output-string 'scheme-indent-function 0)
(put 'call-with-temporary-file 'scheme-indent-function 1)
(put 'call-with-values 'scheme-indent-function 1)
(put 'dolist 'scheme-indent-function 1)
(put 'dotimes 'scheme-indent-function 1)
(put 'if-match 'scheme-indent-function 2)
(put 'let*-values 'scheme-indent-function 1)
(put 'let-args 'scheme-indent-function 2)
(put 'let-keywords* 'scheme-indent-function 2)
(put 'let-match 'scheme-indent-function 2)
(put 'let-optionals* 'scheme-indent-function 2)
(put 'let-syntax 'scheme-indent-function 1)
(put 'let-values 'scheme-indent-function 1)
(put 'let/cc 'scheme-indent-function 1)
(put 'let1 'scheme-indent-function 2)
(put 'letrec-syntax 'scheme-indent-function 1)
(put 'make 'scheme-indent-function 1)
(put 'multiple-value-bind 'scheme-indent-function 2)
(put 'match 'scheme-indent-function 1)
(put 'parameterize 'scheme-indent-function 1)
(put 'parse-options 'scheme-indent-function 1)
(put 'receive 'scheme-indent-function 2)
(put 'rxmatch-case 'scheme-indent-function 1)
(put 'rxmatch-cond 'scheme-indent-function 0)
(put 'rxmatch-if 'scheme-indent-function 2)
(put 'rxmatch-let 'scheme-indent-function 2)
(put 'syntax-rules 'scheme-indent-function 1)
(put 'unless 'scheme-indent-function 1)
(put 'until 'scheme-indent-function 1)
(put 'when 'scheme-indent-function 1)
(put 'while 'scheme-indent-function 1)
(put 'with-builder 'scheme-indent-function 1)
(put 'with-error-handler 'scheme-indent-function 0)
(put 'with-error-to-port 'scheme-indent-function 1)
(put 'with-input-conversion 'scheme-indent-function 1)
(put 'with-input-from-port 'scheme-indent-function 1)
(put 'with-input-from-process 'scheme-indent-function 1)
(put 'with-input-from-string 'scheme-indent-function 1)
(put 'with-iterator 'scheme-indent-function 1)
(put 'with-module 'scheme-indent-function 1)
(put 'with-output-conversion 'scheme-indent-function 1)
(put 'with-output-to-port 'scheme-indent-function 1)
(put 'with-output-to-process 'scheme-indent-function 1)
(put 'with-output-to-string 'scheme-indent-function 1)
(put 'with-port-locking 'scheme-indent-function 1)
(put 'with-string-io 'scheme-indent-function 1)
(put 'with-time-counter 'scheme-indent-function 1)
(put 'with-signal-handlers 'scheme-indent-function 1)
(put 'with-locking-mutex 'scheme-indent-function 1)
(put 'guard 'scheme-indent-function 1)

(global-font-lock-mode t)


;;; emacs lisp
;; emacs-lisp-mode-hook用の関数を定義
(defun elisp-mode-hooks ()
  "lisp-mode-hooks"
  (when (require 'eldoc nil t)
    (setq eldoc-idle-delay 0.2)
    (setq eldoc-echo-area-use-multiline-p t)
    (turn-on-eldoc-mode)))

;; emacs-lisp-modeのフックをセット
(add-hook 'emacs-lisp-mode-hook 'elisp-mode-hooks)

;;; lispxmp
;; 式の評価結果を注釈するための設定
(require 'lispxmp)
;; emacs-lisp-mode で C-c C-d を押すと注釈される
(define-key emacs-lisp-mode-map (kbd "C-c C-d") 'lispxmp)

;;; html5
;; nxml-mode
(add-to-list 'auto-mode-alist '("\\.[sx]?html?\\(\\.[a-zA-Z_]+\\)?\\'" . nxml-mode))
;; html5のスキーマ読み込み
(eval-after-load "rng-loc"
  '(add-to-list 'rng-schema-locating-files "~/.emacs.d/public_repos/html5-el/schemas.xml"))
;; (require 'whattf-dt)

;; </を入力すると自動的にタグを閉じる
(setq nxml-slash-auto-complete-flag t)
;; M-TABでタグを補完
(setq nxml-bind-meta-tab-to-complete-flag t)
;; nxml-modeでauto-complete-modeを利用する
(add-to-list 'ac-modes 'nxml-mode)
;; 子要素のインデント幅を設定。初期値は２
(setq nxml-child-indent 2)
;; 属性値のインデント幅を設定。初期値は４
(setq nxml-attribute-indent 2)

;; ;;; cssm-mode
;; (defun css-mode-hooks ()
;;   "css-mode hooks"
;;   ;; インデントをCスタイルにする
;;   (setq cssm-indent-function #'cssm-c-style-indenter)
;;   ;; インデント幅を２にする
;;   (setq cssm-indent-level 2)
;;   ;; インテントにタブ文字を使わない
;;   (setq-default indent-tabs-mode nil)
;;   ;; 閉じ括弧の前に改行を挿入
;;   (setq cssm-newline-before-closing-bracket t))

;; (add-hook 'css-mode-hook 'css-mode-hooks)

;;; js3-mode
;; (autoload 'js3-mode "js3" nil t)
;; (add-to-list 'auto-mode-alist '("\\.js$" . js3-mode))
;; (defun js3-indent-hook ()
;;   (setq
;;    js3-auto-indent-p t
;;    ; js3-curly-indent-offset 0
;;    js3-enter-indents-newline t
;;    ; js3-expr-indent-offset 2
;;    js3-indent-on-enter-key t
;;    ; js3-lazy-commas t
;;    ; js3-lazy-dots t
;;    ; js3-lazy-operators t
;;    ; js3-paren-indent-offset 2
;;    ; js3-square-indent-offset 4
;;    ))
;; (add-hook 'js3-mode-hook 'js3-indent-hook)

;; (custom-set-variables
;;  '(js3-lazy-commas t)
;;  '(js3-lazy-operators t)
;;  ;; '(js3-expr-indent-offset 2)
;;  ;; '(js3-paren-indent-offset 2)
;;  ;; '(js3-square-indent-offset 2)
;;  ;; '(js3-curly-indent-offset 2)
;;  ;; '(js3-auto-indent-p t)
;;  '(js3-enter-indents-newline t)
;;  '(js3-indent-on-enter-key t))

;; (add-to-list 'ac-modes 'js3-mode)

;;; js-mode
;; (defun js-indent-hook ()
;;   ;; インデント幅を４にする
;;   (setq js-indent-level 2
;;         ;; js-expr-indent-offset 2
;;         js-expr-indent-offset 2
;;         indent-tabs-mode nil)
  ;; switch文のcaseラベルをインデントする関数を定義
  ;; (defun my-js-indent-line ()
  ;;   (interactive)
  ;;   (let* ((parse-status (save-excursion (syntax-ppss (point-at-bol))))
  ;;          (offset (- (current-column) (current-indentation)))
  ;;          (indentation (js--proper-indentation parse-status)))
  ;;     (back-to-indentation)
  ;;     (if (looking-at "case\\s-")
  ;;         (indent-line-to (+ indentation 2))
  ;;       (js-indent-line))
  ;;     (when (> offset 0) (forward-char offset))))
  ;; ;; caseラベルのインデント処理をセット
  ;; (set (make-local-variable 'indent-line-function) 'my-js-indent-line)
  ;; )

;; js-modeの起動時にhookを追加
;;(add-hook 'js-mode-hook 'js-indent-hook)

;; ;; js2-mode
(autoload 'js2-mode' "js2-mode" nil t)
;; (add-to-list 'auto-mode-alist '("\\.js$" . js2-mode))
(add-to-list 'auto-mode-alist '("\\.\\(js\\|jsx\\)$" . js2-mode))
;; (add-to-list 'auto-mode-alist '("\\.\\(js\\|json\\)$" . js2-mode))
;; (add-hook 'js2-mode-hook 'js-indent-hook)

;; (defun js2-enter-and-indent ()
;;   (interactive)
;;   (js2-enter-key)
;;   (js2-insert-and-indent))

;; (define-key js2-mode-map (kbd "C-m") 'js2-enter-and-indent)

;; (when (autoload 'js2-mode "js2-mode" nil t)
;;   (setq js2-cleanup-whitespace t
;;         js2-mirror-mode t)
;;   (defun indent-and-back-to-indendation ()
;;     (interactive)
;;     (indent-for-tab-command)
;;     (let ((point-of-indentation
;;            (save-excursion
;;              (back-to-indentation)
;;              (point))))
;;       (skip-chars-forward "\s" point-of-indentation)))
;;   (define-key js2-mode-map (kbd "C-i") 'indent-and-back-to-indendation)
;;   (define-key js2-mode-map (kbd "C-m") nil)
;;   (add-to-list 'auto-mode-alist '("\\.\\(js\\|json\\)$" . js2-mode)))

;;; json-mode
(setq js-indent-level 2)
(add-to-list 'auto-mode-alist '("\\.json$" . json-mode))
(add-to-list 'ac-modes 'json-mode)

(defun json-indent-hook ()
  (setq tab-width 2))
(add-hook 'json-mode-hook 'json-indent-hook)


;;; ruby-mode
(require 'ruby-mode)
;; rvm.el
;; (require 'rvm)
;; (rvm-use-default)

;; 括弧の自動挿入
;; (require 'ruby-electric nil t)

;; magick comment を自動入力させない
(custom-set-variables '(ruby-insert-encoding-magic-comment nil))

;; ;; endに対する行のハイライト
;; (when (require 'ruby-block nil t)
;;   (setq ruby-block-highlight-toggle t))

;; インタラクティブRubyを利用する
;; (autoload 'run-ruby "inf-ruby"
;;   "Run an inferior Ruby process")
;; (autoload 'inf-ruby-keys "inf-ruby"
;;   "Set local key defs for inf-ruby in ruby-mode")

;; smart compile
(require 'smart-compile)
(define-key ruby-mode-map (kbd "C-c c")   'smart-compile)
(define-key ruby-mode-map (kbd "C-c C-c") (kbd "C-c c C-m"))

;; xmpfilter
(require 'rcodetools)
(define-key ruby-mode-map (kbd "C-c C-d") 'xmp)

;; ruby-mode-hook用の関数を定義
(defun ruby-mode-hooks ()
  ;; (inf-ruby-keys)
  (ruby-electric-mode t)
  (when (require 'ruby-block nil t)
    (setq ruby-block-highlight-toggle t))
  (ruby-block-mode t))

;; ruby-mode-hookに追加
(add-hook 'ruby-mode-hook 'ruby-mode-hooks)
(add-hook 'enh-ruby-mode-hook 'ruby-mode-hooks)

;; rhtml(erb)-mode
(when (require 'rhtml-mode nil t)
  (add-to-list 'auto-mode-alist '("\\.erb\\'" . rhtml-mode)))

;; ;; rubocop
;; (require 'rubocop)
;; (add-hook 'ruby-mode-hook 'rubocop-mode)
;; (add-hook 'enh-ruby-mode-hook 'rubocop-mode)

;;;; scala-mode
;; (require 'scala-mode-auto)
;; (require 'scala-mode-feature-electric)
;; (add-hook 'scala-mode-hook
;;           (lambda ()
;;             (scala-electric-mode)))

(require 'scala-mode2)

;; ;;; java-mode (malabar-mode)
;; (setq semantic-default-submodes '(global-semantic-idle-scheduler-mode
;;                                   global-semantic-minor-mode
;;                                   global-semantic-idle-summary-mode
;;                                   global-semantic-mru-bookmark-mode))
;; (semantic-mode 1)
;; (require 'malabar-mode)
;; (setq malabar-groovy-lib-dir "~/.emacs.d/public_repos/malabar-mode/lib")
;; (add-to-list 'auto-mode-alist '("\\.java\\'" . malabar-mode))

;; (add-to-list 'ac-modes 'malabar-mode)


;;; yaml-mode
(when (require 'yaml-mode nil t)
 (add-to-list 'auto-mode-alist '("\\.yml$" . yaml-mode)))

(add-hook 'yaml-mode-hook
          '(lambda ()
             (define-key yaml-mode-map "\C-m" 'newline-and-indent)))

;;; arduino-mode
;; (require 'arduino-mode)
(autoload 'arduino-mode "arduino-mode" "Arduino editing mode." t)
;; (add-to-list 'load-path "~/.emacs.d/public_repos/arduino-mode")
(setq auto-mode-alist (cons '("\\.\\(pde\\|ino\\)$" . arduino-mode) auto-mode-alist))
;; (add-to-list 'auto-mode-alist '("\\.\\(pde\\|ino\\)$" . arduino-mode))
(add-to-list 'ac-modes 'arduino-mode)

;;; web-mode
(require 'web-mode)

(when (< emacs-major-version 24)
  (defalias 'prog-modef 'fundamental-mode))

(add-to-list 'auto-mode-alist '("\\.phtml$"     . web-mode))
(add-to-list 'auto-mode-alist '("\\.tpl\\.php$" . web-mode))
(add-to-list 'auto-mode-alist '("\\.jsp$" . web-mode))
(add-to-list 'auto-mode-alist '("\\.as[cp]x$" . web-mode))
;; (add-to-list 'auto-mode-alist '("\\.erb$" . web-mode))
(add-to-list 'auto-mode-alist '("\\.html?$" . web-mode))

(defun web-mode-hook ()
  "Hooks for Web mode."
  (setq web-mode-html-offset   2)
  (setq web-mode-css-offset    2)
  (setq web-mode-script-offset 2)
  (setq web-mode-php-offset    2)
  (setq web-mode-java-offset   2)
  (setq web-mode-asp-offset    2))
(add-hook 'web-mode-hook 'web-mode-hook)
(add-to-list 'ac-modes 'web-mode-hook)

;; markdown-mode
(setq markdown-indent-on-enter t)
(add-to-list 'ac-modes 'markdown-mode)

;;; C-mode
(require 'google-c-style)
(add-hook 'c-mode-common-hook 'google-set-c-style)
(add-hook 'c-mode-common-hook 'google-make-newline-indent)

;; ;;; android-mode
;; (require 'android-mode)
;; (setq android-mode-sdk-dir "/usr/local/opt/android-sdk")

;; コマンド用プレフィックス
;; ここで設定したキーバインド+android-mode.elで設定された文字、で各種機能を利用可能
(setq android-mode-key-prefix (kbd "C-c C-c"))

;; デフォルトで起動するエミュレータ名
(setq android-mode-avd "emudroid")

;;; scss-mode

;; inspired by http://d.hatena.ne.jp/CortYuming/20120110/p1
(defun my-css-electric-pair-brace ()
  (interactive)
  (insert "{") (newline-and-indent)
  (newline-and-indent)
  (insert "}")
  (indent-for-tab-command)
  ;; (newline-and-indent)
  ;; (previous-line)
  (previous-line)
  (indent-for-tab-command))

(defun my-semicolon-ret ()
  (interactive)
  (insert ";")
  (newline-and-indent))

(add-to-list 'auto-mode-alist '("\\.\\(scss\\|css\\)$" . scss-mode))
;; (add-to-list 'auto-mode-alist '("\\.scss\\'" . scss-mode))
(add-hook 'scss-mode-hook 'ac-css-mode-setup)
(add-hook 'scss-mode-hook
          (lambda ()
            (define-key scss-mode-map (kbd "M-{") 'my-css-electric-pair-brace)
            ;; (define-key scss-mode-map ";" 'my-semicolon-ret)
            (setq css-indent-offset 2)
            (setq scss-compile-at-save nil)))
(add-to-list 'ac-modes 'scss-mode)

;;; Haskell
;; https://github.com/haskell/haskell-mode/blob/master/examples/init.el
;; (load "haskell-site-file")
;; (load "haskell-mode-autoloads")

;; (autoload 'ghc-init "ghc" nil t)
;; (autoload 'ghc-debug "ghc" nil t)
;; (add-hook 'haskell-mode-hook (lambda () (ghc-init)))
;; (add-hook 'haskell-mode-hook 'turn-on-haskell-simple-indent)
(add-hook 'haskell-mode-hook 'turn-on-haskell-indent)
(add-hook 'haskell-mode-hook 'interactive-haskell-mode)

(custom-set-variables
 '(haskell-process-suggest-remove-import-lines t)
 '(haskell-process-auto-import-loaded-modules t)
 '(haskell-process-log t))

;; (define-key haskell-mode-map (kbd "C-c C-l") 'haskell-process-load-or-reload)
;; (define-key haskell-mode-map (kbd "C-`") 'haskell-interactive-bring)
;; (define-key haskell-mode-map (kbd "C-c C-t") 'haskell-process-do-type)
;; (define-key haskell-mode-map (kbd "C-c C-i") 'haskell-process-do-info)
;; (define-key haskell-mode-map (kbd "C-c C-c") 'haskell-process-cabal-build)
;; (define-key haskell-mode-map (kbd "C-c C-k") 'haskell-interactive-mode-clear)
;; (define-key haskell-mode-map (kbd "C-c c") 'haskell-process-cabal)
;; (define-key haskell-mode-map (kbd "SPC") 'haskell-mode-contextual-space)

;; ;; Customization
;; (custom-set-variables
;;  ;; Use ghci
;;  '(haskell-proce-tyle 'ghci)

;;  '(haskel-notify-p t)

;;  ;; To enable tags genertion on save.
;;  '(haskell-tags-on-save t)

;;  ;; To enable stylish on save.
;;  '(haskell-stylish-on-save t))

;; ;; Haskell main editing mode key bindings
;; (defun haskell-hook ()
;;   ;; Use simple indentation.
;;   (turn-on-haskell-simple-indent)
;;   (define-key haskell-mode-map (kbd "C-m")      'haskell-simple-indent-newline-same-col)
;;   (define-key haskell-mode-map (kbd "<return>") 'haskell-simple-indent-newline-indent)

;;   ;; Load the current file (and make a session if not already made).
;;   (define-key haskell-mode-map [?\C-x ?\C-l] 'haskell-process-load-file)
;;   (define-key haskell-mode-map [f5]          'haskell-process-load-file)

;;   ;; Switch to the REPL
;;   ;; (define-key haskell-mode-map [?\C-c s] 'haskell-interactive-switch)
;;   (define-key haskell-mode-map "\C-cs" 'haskell-interactive-switch)

;;   ;; "Bring" the REPL, hiding all other windows apart from the source and the REPL
;;   (define-key haskell-mode-map (kbd "C-`") 'haskell-interactive-bring)

;;   ;; Get the type and info of the symbol at point, print it in the message buffer
;;   (define-key haskell-mode-map (kbd "C-c C-t") 'haskell-process-do-type)
;;   (define-key haskell-mode-map (kbd "C-c C-i") 'haskell-process-do-info)

;;   ;; ;; Contextually do clever things on the space key, in particular:
;;   ;; ;;   1. Complete imports, letting you choose the module name.
;;   ;; ;;   2. Show the type of the symbol after the space
;;   (define-key haskell-mode-map (kbd "SPC") 'haskell-mode-contextual-space)

;;   ;; Jump to the imports. Keep tappgin to jump to between import groups.
;;   ;; C-u f8 to jump back again.
;;   (define-key haskell-mode-map [f8] 'haskell-navigate-imports)

;;   ;; Jump to the definition of the current symbol.
;;   (define-key haskell-mode-map (kbd "M-.") 'haskell-mode-tag-find)

;;   ;; Indent the below lines on columns after the current column.
;;   (define-key haskell-mode-map (kbd "C-<right>")
;;     (lambda ()
;;       (interactive)
;;       (haskell-move-nested 1)))
;;   ;; Same as above but backwards.
;;   (define-key haskell-mode-map (kbd "C-<left>")
;;     (lambda ()
;;       (interactive)
;;       (haskell-move-nested -1))))
;; ;(add-hook 'haskell-mode-hook 'turn-on-haskell-doc-mode)

;; ;; (add-hook 'haskell-mode-hook 'turn-on-haskell-indentation)
;; ;;(add-hook 'haskell-mode-hook 'turn-on-haskell-indent)
;; ;; (add-hook 'haskell-mode-hook 'turn-on-haskell-simple-indent)
;; (add-hook 'haskell-mode-hook 'haskell-hook)

;; haskell-modeでauto-complete-modeを利用する
;; (add-to-list 'ac-modes 'haskell-mode)

;; ;;; Dart mode
;; (add-to-list 'ac-modes 'dart-mode)

;;; Python
;; flake8を使えるようにする
(add-hook 'python-mode-hook 'flymake-python-pyflakes-load)
(setq flymake-python-pyflakes-executable "flake8")

;; jedi
(require 'jedi)
(add-hook 'python-mode-hook 'jedi::setup)
(setq jedi:complete-on-dot t)

;;; coffee-mode
(defun coffee-custom ()
  "coffee-mode-hook"
  (and (set (make-local-variable 'tab-width) 2)
       (set (make-local-variable 'coffee-tab-width) 2))
  )

(add-hook 'coffee-mode-hook
          '(lambda () (coffee-custom)))

(add-to-list 'ac-modes 'coffee-mode)


;;; nginx-mode
(require 'nginx-mode)
(add-to-list 'auto-mode-alist '("nginx\\(.*\\).conf[^/]*$" . nginx-mode))


;;; warp-mode
(require 'warp)
(global-set-key (kbd "C-c C-w C-w") warp-mode) ;; Modify key bind as you want.

;; ;; Set markdown converter (if you want)
;; (add-to-list 'warp-format-converter-alist
;;              '("\\.md\\|\\.markdown" t (lambda ()
;;                                          ;; Set command you are using
;;                                          '("markdown"))))

;; Below line is needed if you installed websocket npm module globally.
;; (setenv "NODE_PATH" "/path/to/global/node_modules")
;; ;; or, if you have setup NODE_PATH in the shell
;; (setenv "NODE_PATH"
;;         (replace-regexp-in-string
;;          "\n+$" "" (shell-command-to-string "echo $NODE_PATH")))

;; --------------
;; flycheck-mode
;; --------------
(require 'flycheck)
;; (add-hook 'ruby-mode-hook 'flycheck-mode)
;; ;; (add-hook 'enh-ruby-mode-hook 'flycheck-mode)
;; (flycheck-define-checker ruby-rubocop
;;                          "A Ruby syntax and style checker using the RuboCop tool.
;; See URL `http://batsov.com/rubocop/`."
;;                          :command ("rubocop" "--format" "emacs" "--silent"
;;                                    (config-file "--config" flycheck-rubocoprc)
;;                                    source)
;;                          :error-patterns
;;                          ((warning line-start
;;                                    (file-name) ":" line ":" column ": " (or "C" "W") ": " (message)
;;                                    line-end)
;;                           (error line-start
;;                                  (file-name) ":" line ":" column ": " (or "E" "F") ": " (message)
;;                                  line-end))
;;                          :modes (enh-ruby-mode ruby-mode))
(add-hook 'ruby-mode-hook
          '(lambda ()
             (setq flycheck-checker 'ruby-rubocop)
             (flycheck-mode 1)))

;; ;; php-mode
;; ;; (add-hook 'php-mode-hook (lambda ()
;; ;;                            (defun ywb-php-lineup-arglist-intro (langelem)
;; ;;                              (save-excursion
;; ;;                                (goto-char (cdr langelem))
;; ;;                                (vector (+ (current-column) c-basic-offset))))
;; ;;                            (defun ywb-php-lineup-arglist-close (langelem)
;; ;;                              (save-excursion
;; ;;                                (goto-char (cdr langelem))
;; ;;                                (vector (current-column))))
;; ;;                            (c-set-offset 'arglist-intro 'ywb-php-lineup-arglist-intro)
;; ;;                            (c-set-offset 'arglist-close 'ywb-php-lineup-arglist-close)))
;; (add-hook 'php-mode-hook
;;           '(lambda()
;;              (setq tab-width 4)
;;              (setq indent-tabs-mode nil)
;;              (setq c-basic-offset 4)))


;; ;; -----------
;; ;; tramp
;; ;; -----------
;; ; tramp-default-proxies-alist <- (HOST USER PROXY)
;; ;; (add-to-list 'tramp-default-proxies-alist
;; ;;              '(nil "\\`root\\'" "/ssh:%h:"))
;; ;; (add-to-list 'tramp-default-proxies-alist
;; ;;              '(".*" "\\`root\\'" "/ssh:%h:"))
;; ;; (add-to-list 'tramp-default-proxies-alist
;; ;;              '("localhost" nil nil))
;; ;; (add-to-list 'tramp-default-proxies-alist
;; ;;              '((regexp-quote (system-name)) nil nil))
;; ;; (add-to-list 'tramp-default-proxies-alist
;; ;;              '("49.212.131.62#2323" "fumitaka" "/ssh:fumitaka@49.212.131.62#2323"))
;; ;; (add-to-list 'tramp-default-proxies-alist
;; ;;              '("49.212.131.62" "\\`root\\'" "/ssh:49.212.131.62#2323:"))
;; ;; (add-to-list 'tramp-default-proxies-alist
;; ;;              '("49.212.131.62" "\\`fumitaka\\'" "/ssh:49.212.131.62#2323:"))
;; ;; (set-default 'tramp-default-proxies-alist
;; ;;              (quote ((".*" "\\`root\\'" "/ssh:%h:"))))
