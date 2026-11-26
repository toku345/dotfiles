# ADR 0043: gw は素の git worktree で実装し、作成後のセットアップは git の hook に任せる

## Status

Accepted (2026-11-26). [ADR 0004](0004-git-workflow-command-reorganization.md) の `git gtr` への作成委譲と、[ADR 0006](0006-worktree-cleanup-commands.md) の `git gtr rm` への削除委譲を置き換える。

## Context

`gw` 系コマンド（`gw`、`gw -c`、`gw rm`、`gw clean`）は worktree の作成・移動・削除を git-gtr に委ねていた。git-gtr は上流でアーカイブされたと報告されており、今後の修正が見込めない。一方、`gw` が git-gtr から使っていた機能は、配置先の命名、ブランチの追跡設定、fetch、削除とブランチ削除に限られ、いずれも `git worktree` と `git branch` で書ける。git-gtr を使い続けた唯一の利点は、リポジトリごとの `.gtrconfig` に書いた作成後処理（依存のコピー、個人設定の symlink、`bun install` など）だった。現行の Git（2.56 で確認）は config に `hook.<name>.command` / `hook.<name>.event` を書くだけで hook を登録でき、`post-checkout` は `git worktree add` の直後に null-ref を第 1 引数として呼ばれる。

## Decision

`gw` 系は `git worktree add` / `git worktree remove` / `git branch -D` を直接呼ぶ。配置先は git-gtr と同じ `<main repo>-worktrees/<ブランチ名の記号を - に置換した名前>` を保ち、既存の worktree と sandbox の書き込み許可をそのまま使えるようにする。base は手元の ref、なければ `origin/<base>` から commit SHA に解決してから `-b` に渡し、remote にしかないブランチは `--track origin/<branch>` で作る。明示的な base や remote のブランチを使う経路だけ `git fetch origin` を試し、失敗は警告にとどめて手元の ref で続ける。引数なしの `gw` は fetch せず手元の default ブランチから作る。手元に base があれば fetch 後もそちらを優先するのは git-gtr と同じで、最新から切るには `origin/<base>` を指定する。`gw rm` は worktree のディレクトリが存在しない場合は止まる（`git worktree remove` はディレクトリが無いと未コミットの確認を飛ばして登録を消すため）。インストールスクリプトからは git-gtr を外す。

作成後のセットアップは `gw` に持たせず、各リポジトリの `git config --local` に登録した `post-checkout` hook で行う。こうすると `gw` を経由しない `git worktree add`（エージェントが作る worktree を含む）でも同じセットアップが走る。hook の本体と設定はリポジトリごとのローカル領域（`.git/info/` 等）に置き、chezmoi では配布しない。hook は第 1 引数が null-ref のときだけ動く。調査用に任意のコミットを展開する detached HEAD では依存のインストールや `direnv allow` を走らせないよう何もしないが、ブランチ付きの worktree では、そのブランチの内容に対してセットアップが走る。セットアップを止めたい作成では `git -c hook.<name>.enabled=false worktree add …` を使う。

## Consequences

外部ツールへの依存が 1 つ減り、終了コードが git 本体のものになるため、`git gtr rm` が失敗時も 0 を返す問題への回避策が不要になった。`gw` は hook が失敗した場合も worktree を残し、作成済みでセットアップだけ失敗したことを表示してその worktree に移動する。セットアップを再実行できるよう、hook のスクリプトは繰り返し実行しても壊れないように書く必要がある。

hook は `gw` 以外の経路でも動くため、エージェントがブランチ付きの worktree を作るたびに依存のインストール等が走り、所要時間が延びる。git-gtr にあった削除時の hook（`preRemove` / `postRemove`）、宣言的なファイルコピー（`gtr.copy.*`）、sparse checkout の継承元を base 側に合わせる処理、エディタや AI ツールの起動連携は引き継がない。インストールスクリプトの内容が変わるため、既存のマシンでも次の `chezmoi apply` で一度だけ再実行される。Linux では `sudo apt-get` のためにパスワードを求められ、パッケージの導入が 1 つでも失敗すると `set -eu` で止まり、その apply では dotfiles が適用されない。インストール済みの git-gtr は自動では削除されない。
