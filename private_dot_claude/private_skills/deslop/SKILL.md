---
name: deslop
description: >
  Remove AI-generated code slop from current branch.
  Identifies and removes inconsistent comments, over-defensive code patterns,
  and style mismatches introduced by AI.
  Use when: cleaning up AI-generated code, before committing AI changes,
  after code generation session.
user-invocable: true
allowed-tools:
  - Read
  - Edit
  - Bash
---

# Remove AI Code Slop

main ブランチとの差分を確認し、このブランチで導入された AI 特有の冗長な記述を削除してください。

## 削除対象

- ファイル内の他のコードと整合性のないコメント
- コードベースの慣習にそぐわない防衛的コード（過剰な nil チェック、不要な try/catch）
- ファイル全体のスタイルと矛盾する記述

## 手順

1. `git diff main...HEAD` で変更箇所を把握
2. 各ファイルの既存スタイルを確認し、基準に基づき修正
3. 変更内容を1〜3文で要約報告
