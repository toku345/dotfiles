---
name: pr-review
description: >
  Cursor pre-PR review gate based on the Codex pr-review procedure.
  Use only when the user explicitly invokes /pr-review. Launches the Codex
  specialists as Cursor subagents, then normalizes severity and verifies
  Critical and Important findings.
disable-model-invocation: true
---

# pr-review (Cursor)

Codex 版の pre-PR gate を、Cursor の subagent で実行する。specialist の指示の正本は `private_dot_codex/agents/*.toml`。実行時に読むのは、この SKILL.md と同じディレクトリの `agents/`、`references/`、`scripts/`。`agents/*.md` の指示本文は toml の `developer_instructions` で、その前に subagent を起動しない一行だけ足してある。`references/` と `scripts/` は Codex の同じファイルと同じバイト列。

Claude 版との検出差は #482 の範囲で、この手順は Codex 版に合わせる。

この SKILL.md を読んだディレクトリを skill ルートとする。

## 呼ばれたら

1. **共有ファイル**を読み、sentinel を確認する。欠ける・一致しない・JSON として読めない場合は、specialist を起動せずに止まる。
   - `references/review-criteria.md` に `PR_REVIEW_CRITERIA_SHARED_V1`
   - `references/severity-rules.json` の `sentinel` が `PR_REVIEW_SEVERITY_RULES_V1` で `version` が `1`
   - `references/finding-verifier-contract.json` に `PR_REVIEW_FINDING_VERIFIER_CONTRACT_V1`
2. **作業ツリー**。`git status --porcelain --untracked-files=normal` が失敗したらその出力で止まる。出力が空でなければ、一覧を示して止まる。見るのは commit 済みの差分だけなので、未 commit の変更は commit するか stash してからやり直す。
3. **base**。次の順で一つだけ選ぶ。fetch や `gh` が失敗したら、そのコマンドの失敗を短く示し、40文字の commit OID を base として再実行するよう伝えて止まる。
   - プロンプトの明示 base。40文字の16進 OID ならネットワークも fetch も使わず、それを `$BASE_REF` にする。それ以外はブランチ名として `git check-ref-format --branch` を通し、先頭の `-`/`+`、`:`、その他の refspec 区切りを拒否する。通ったら `git fetch --quiet origin "refs/heads/$BASE"` し、`$BASE_REF=FETCH_HEAD` としてすぐ commit を確定する。
   - プロンプトの `--allow-no-pr`、または `ALLOW_NO_PR` が `1` / `true`。`gh` は使わない。`git fetch --quiet origin` と `git remote set-head origin --auto` がどちらも成功してから `git symbolic-ref --quiet --short refs/remotes/origin/HEAD` を読む。失敗か空なら止まる。`origin/` を除いた名前を `$BASE`、読んだ ref 全体を `$BASE_REF` にし、最終報告に `**Degraded coverage**: no PR base, fell back to default branch` を入れる。
   - 開いている PR。`gh pr view --json baseRefName,baseRefOid --jq '[.baseRefName,.baseRefOid] | @tsv'`。`no pull request found` のときだけ PR なし。それ以外の失敗は止まる。成功したらブランチ名を明示 base と同じ規則で検査し、`git fetch --quiet origin "refs/heads/$BASE"` のあと `FETCH_HEAD^{commit}` が返った OID と一致することを確認する。違う場合は両方の OID を示して止まる。一致したら `$BASE_REF=FETCH_HEAD`。
   - どれでも決まらなければ止まる。draft PR を作るか、明示 base か `--allow-no-pr` が要る。
4. **pin**。`$BASE_REF` を決めた直後に `git rev-parse --verify "$BASE_REF^{commit}"` し、その出力を `$BASE_COMMIT` とする。失敗したら止まる。
5. **収集**。先に `git rev-parse HEAD` だけを実行し、成功した commit OID を `$HEAD_REF` とする。失敗したら止まる。そのあと `$HEAD_REF` を使い、`git status --short`、`git log --no-decorate "$BASE_COMMIT..$HEAD_REF"`、`git diff --name-only "$BASE_COMMIT...$HEAD_REF"`、`git diff "$BASE_COMMIT...$HEAD_REF"` を実行する。どれかが失敗したら止まる。name-only が空なら、下の最終ガードを実行してから `No committed changes relative to <base>; nothing to review.` と返して止まる。
6. **diff packet**。`mktemp "${TMPDIR:-/tmp}/pr-review-diff.XXXXXX"` で作ったファイルへ diff を書き、バイト数と SHA-256 を記録する。suffix 付きの mktemp は使わない。どれかが失敗したら止まる。packet が specialist の正本になる。

## specialist

変更パスを次で分ける。迷ったら specialist を足す。

- `test_paths`: `tests/`、`test/`、`__tests__/`、`*.test.*`、`*.spec.*`、`*_test.go`、`*_spec.rb`、`*.bats`、basename が `test_` で始まるもの。パスの途中に `test` という役割名があるだけの実行ファイルはテストにしない。
- `operational_paths`: `private_dot_codex/skills/**/SKILL.md`、`private_dot_codex/agents/*.toml`、`.github/workflows/**`、`.claude/hooks/**`、`.chezmoiscripts/**`、`dot_local/bin/**`、ツールの挙動を変える shell や設定。
- `docs_paths`: `docs/`、`*.md`、`README*` のうち `operational_paths` でないもの。
- `code_paths`: 受動的な docs だけではない変更パス。`operational_paths` はすべて含める。
- `comment_changes`: 追加または削除されたコメント行。
- `docs_or_comments`: `docs_paths` か `comment_changes` がある。
- `type_changes`: `class` / `interface` / `type` / `struct` / `enum` / `trait` / `dataclass` / schema 定義の追加、または既存の型・schema 定義の中の変更。

Stage 1 は次の順で、条件を満たすものだけを起動する。

1. `code-reviewer`
2. `security-reviewer`
3. `adversarial-reviewer`
4. `pr-test-analyzer`（`code_paths` があるとき）
5. `comment-analyzer`（`docs_or_comments` があるとき）
6. `silent-failure-hunter`（`code_paths` があるとき）
7. `type-design-analyzer`（`type_changes` があるとき）

## 起動

Cursor の Task ツールで subagent を起動する。Codex の `spawn_agent` は使わない。

- 同じメッセージに、その stage の specialist を1人ずつ Task で出す。`run_in_background` と `machine` と `model` は付けない。
- Task の subagent 一覧にその名前があるときは、その `subagent_type` を使う。名前の定義は、このリポジトリの `.cursor/agents/` と、`chezmoi apply` 後の `~/.cursor/agents/` にある。`~/.cursor/agents` は cloud agent へ同期されない。
- 一覧に名前が無いときは `generalPurpose` を使い、prompt に `agents/<name>.md` の frontmatter のあとの本文を入れる。`agents/<name>.md` が読めなければ止まる。`generalPurpose` には readonly の指定が無いので、編集しないことを prompt に書き、最終ガードで作業ツリーを見る。
- どちらの場合も prompt に、対象ブランチ、`$BASE`、`$BASE_REF`、`$BASE_COMMIT`、`$HEAD_REF`、分類した変更ファイル、`git status --short`、`git log`、packet のパス・バイト数・SHA-256、review-only（ファイルを編集しない）を入れる。Stage 2 には Stage 1 で既に挙がった指摘の短い要約を足す。Stage 3 には候補1件と verifier contract のパスを足し、他の指摘は入れない。
- 結果が揃うまで次の stage へ進まない。起動失敗、空の結果、打ち切り、sentinel 不一致は、その stage を失敗として止まる。届いた一部だけで集約しない。

Stage 1 と Stage 2 の最初の行は `COVERAGE_OK <name> $BASE_COMMIT...$HEAD_REF <packet_sha256>` か `FATAL_COVERAGE_ERROR <name>: <reason>` である。`COVERAGE_OK` の名前・範囲・SHA-256 が記録と違う、または fatal のときは止まる。

## 重要度と検証

`references/review-criteria.md` と `references/severity-rules.json` で Stage 1 の指摘を正規化する。specialist のラベルはそのまま最終重要度にしない。指摘の必須項目は `blocking`、`impact_scope`、`verified_assumptions`、`unverified_assumptions` の4つ。`severity-rules.json` の confidence しきい値は、その表の重要度判定にだけ使う。

同じ根因の指摘は1件にまとめ、出した specialist 名は残す。正規化後の Critical と Important だけを検証候補にする。ID は `f001` から、Critical、Important の順、その中では Stage 1 の起動順、同じ specialist の中では出現順。Stage 2 の結果で ID も候補の集合も変えない。

Critical が1件も無いときだけ Stage 2 で `code-simplifier` を1人起動する。Critical があるときは Stage 2 をしない。Stage 2 にも同じ sentinel 検査を適用する。

Stage 3 は候補が空なら起動しない。あるときは候補ごとに `finding-verifier` を1人、並列に起動する。新しい指摘の発見や重要度の変更はさせない。最初の行は `VERIFICATION_OK finding-verifier <candidate_id> $BASE_COMMIT...$HEAD_REF <packet_sha256>` か `FATAL_VERIFICATION_ERROR finding-verifier <candidate_id>: <reason>`。`VERIFICATION_OK` のあとは contract どおりの JSON オブジェクト1つ。候補の過不足、sentinel や hash の不一致、JSON の不正は止まる。

各 JSON オブジェクトだけを作業ツリーの外の一時ファイルに書き、次を実行する。

```sh
python3 <skill>/scripts/validate_finding_evidence.py \
  --repo-root <repo> \
  --head-ref "$HEAD_REF" \
  --result-file <json-file>
```

終了コード 0 かつ stdout が `EVIDENCE_OK finding-verifier <candidate_id> $HEAD_REF <evidence_count>` であること。それ以外は止まる。作業ツリー上のファイルでは検証しない。

判定の適用は、`confirmed` は正規化後の重要度を残す。`refuted` は修正対象から外し、Refuted Findings に残す。`needs-verification` は `missingVerification` が空でなく、Critical を Important に下げる。Important の `needs-verification` は Important のまま。`confirmed` と `refuted` は evidence が空でなく `missingVerification` は空。それ以外の組み合わせは止まる。

## 最終ガードと報告

集約の前に `git status --porcelain --untracked-files=normal` を再実行する。失敗したらその出力で止まる。空でなければ、レビュー中に作業ツリーが変わったとして一覧を示して止まる。`git rev-parse HEAD` が `$HEAD_REF` と違えば、開始時と現在の OID を示して止まる。

packet と evidence の一時ファイルは消さない。

`output_caps` の件数まで Important と Suggestion を載せる。Critical と Important には候補 ID と specialist 名を残す。Recommended Action には、Critical と Important が両方 0 なら gate を止めること、Suggestion だけでは再実行しないこと、2回目以降は前回の Critical / Important の解消を見ること、3回目以降で指摘が安定せず入れ替わるときは人に返すことを書く。

```markdown
# PR Review: <branch> vs <base>

<degraded-coverage line if applicable>

## Verification Summary
- Confirmed: X; Needs verification: Y; Refuted: Z

## Critical Issues (X found)
- [<candidate-id> / <specialist>]: <description> [<file>:<line>]
  - Impact scope: ...
  - Verified assumptions: ...
  - Unverified assumptions: ...
  - Why it matters: ...
  - Suggested fix: ...

## Important Issues (X shown, capped)
- [<candidate-id> / <specialist>]: <description> [<file>:<line>]
  - Impact scope: ...
  - Missing verification: <if any>

## Suggestions (X shown, capped)
- [<specialist>]: <description> [<file>:<line>]

## Refuted Findings
- [<candidate-id> / <specialist>]: <original description>
  - Verifier summary: ...

## Strengths
- <positive observations>

## Recommended Action
1. Fix Critical issues first
2. Address Important issues
3. Consider Suggestions
4. Re-run after fixes to verify prior Critical and Important findings
5. Stop when Critical 0 / Important 0
6. On the third or later pass, if Critical or Important findings churn, return the decision to a human
```
