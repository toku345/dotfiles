---
name: pr-review
description: >
  Cursor の IDE、CLI、cloud agent から呼ぶ pre-PR review の入口。
  /pr-review と明示したときだけ使う。Claude 版と Codex 版のどちらを
  手順の正本にするかは未決なので、この skill はレビューを実行しない。
disable-model-invocation: true
---

# pr-review (Cursor)

Cursor で `/pr-review` を呼べるようにする入口。レビュー手順はまだない。

## 呼ばれたら

レビューをしない。specialist を起動しない。diff を読んで指摘を書かない。次の3点を返して止まる。

1. この skill は入口だけで、レビュー本体は未決。
2. 未決は、Claude 版と Codex 版のどちらを Cursor の手順にするか。
3. 今レビューするなら、Codex が使える端末では Codex の `$pr-review`、使えない環境では Claude Code の `/pr-review`。Cursor の組み込み `/review` はこの gate ではない。

## なぜ手順を置いていないか

共有しているのは `private_dot_codex/skills/pr-review/references/review-criteria.md` と `severity-rules.json` だけ。結果が変わる差が残っている。

- 指摘の項目。Claude の workflow は `confidence` を必須にする。共有ポリシーと Codex は `blocking`、`impact_scope`、`verified_assumptions`、`unverified_assumptions` の4つ。
- specialist の出し分け。Claude は `scripts/routing-flags.sh` の結果と categorizer の論理和。Codex は categorizer の判断だけ。
- 起動方法。Claude は `~/.claude/workflows/pr-review.js`。Codex は `spawn_agent` の V1/V2 と `~/.codex/agents/*.toml`。Cursor にはそのどちらもない。

#436 は片方へ寄せずに共通化する話、#482 はその検出差を先に測る話。ここへどちらかの手順を写すと、その選択になる。

## どこから読まれるか

- 正本はこのファイル。このリポジトリを開いている Cursor（手元の IDE / CLI と、このリポジトリの cloud agent）は `.cursor/skills/pr-review/SKILL.md` を読む。
- 他のディレクトリの手元の Cursor は、`chezmoi apply` 後の `~/.cursor/skills/pr-review/SKILL.md` を読む。中身は `dot_cursor/skills/pr-review/SKILL.md.tmpl` が正本を include したもので、apply 後は同じバイト列になる。
- 他リポジトリの cloud agent は、Settings → Agents → Sync Skills for Cloud Agents がオンのときだけ、その `~/.cursor/skills/` を読む。同期されるのは `~/.cursor/skills/` だけで、`~/.agents/skills/`、`~/.claude/skills/`、`~/.codex/skills/` は cloud agent にコピーされない。automation は同期した個人 skill を読まない。
- 手元の Cursor は、適用済みの `~/.claude/skills/pr-review` と `~/.codex/skills/pr-review` も互換パスとして読む。`/pr-review` が複数出たら、path が `.cursor/skills/pr-review` か `~/.cursor/skills/pr-review` のものを選ぶ。
