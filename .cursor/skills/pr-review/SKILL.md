---
name: pr-review
description: >
  Cursor entry for the Codex pr-review gate. Use only when the user invokes
  /pr-review. Read the Codex procedure and specialist toml in place. Do not
  copy them.
disable-model-invocation: true
---

# pr-review (Cursor)

Codex の pr-review を Cursor の Task で実行する。手順も specialist もこのファイルには写さない。

## 正本

最初に読める方を使う。

1. 作業ツリーの `private_dot_codex/skills/pr-review/SKILL.md` と `private_dot_codex/agents/*.toml`
2. `~/.codex/skills/pr-review/SKILL.md` と `~/.codex/agents/*.toml`

どちらも読めなければ止まる。手順を作り直さない。他リポジトリの cloud agent はここに当たる。共通化は #436。

## 実行

正本の SKILL.md に従う。Cursor に合わせるのは起動だけ。`references/` と `scripts/` は、開いた正本 SKILL.md と同じディレクトリを使う。

- 正本の Preconditions の V1/V2 runtime contract は飛ばす。`spawn_agent`、`wait_agent`、`list_agents`、`close_agent`、`interrupt_agent` は実行しない。
- specialist は Task で起動する。同じメッセージに、その stage の人数分を出す。`run_in_background`、`machine`、`model` は付けない。
- 一覧にその名前があればその `subagent_type` を使う。無ければ `generalPurpose` を使い、対応する toml の `developer_instructions` を prompt に入れる。
- prompt には、正本が specialist に渡す packet（base、HEAD、diff packet、hash、scope）を入れる。ファイルは編集させない。
- sentinel、重要度、verifier、集約、作業ツリーの最終確認は正本のまま行う。届いた一部だけでは集約しない。

Claude 版との検出差は #482。この入口は Codex の正本に従う。
