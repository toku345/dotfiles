# Issue #193 probe log

Working log for [Issue #193](https://github.com/toku345/dotfiles/issues/193). Investigation framework, decision tree, and option enumeration are recorded in [ADR 0021](../adr/0021-triple-review-adv-revert-investigation.md). This file holds probe command transcripts and result records.

## Step 0 — upstream state snapshot (2026-05-09)

| Issue | State | Last activity |
|---|---|---|
| `openai/codex-plugin-cc#270` (gpt-5.5 default broken) | open | 2026-04-26 |
| `openai/codex-plugin-cc#183` (captureTurn await forever) | open | 2026-04-08 |
| `openai/codex-plugin-cc#305` (gpt-5.4 + gpt-5.5 reject `tools: 'custom'`) | closed 2026-05-08 (`"filing in our internal tracker"`) | 2026-05-08 |

`#305` reports a regression window starting at CLI `0.128.0` where `--model gpt-5.4` itself returns `unknown_parameter` 400. Local `codex-cli` is `0.130.0` (newer than the #305 reporter's environment), so the `gpt-5.4` pin's continued viability could not be assumed from upstream state alone. Step 0a smoke test below resolves that ambiguity.

## Step 0a — smoke test (gpt-5.4 pin, current workaround configuration)

Verifies that the **current** workaround path still functions on the local 2026-05-09 environment, **before** designing any revert probe. Codex's own adversarial review on this log (during the probe) flagged that conflating "workaround path success" with "revert is safe" is a false-confidence risk; Step 0a deliberately tests only the workaround path, and Stage 1 / 2 below test the revert path independently.

```bash
CODEX_COMPANION="$HOME/.claude/plugins/cache/openai-codex/codex/1.0.4/scripts/codex-companion.mjs"
LOGDIR="$TMPDIR/issue-193-probe"
mkdir -p "$LOGDIR"
# perl alarm = pure-stdlib timeout (macOS lacks coreutils `timeout` by default).
# 600 s cap matches Codex's typical 3-7 min completion + safety margin.
perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!"' 600 \
  node "$CODEX_COMPANION" adversarial-review --base main --scope branch --model gpt-5.4 \
  > "$LOGDIR/adv.md" 2> "$LOGDIR/adv.err"
```

### Result (2026-05-09 17:55:13 — 17:56:39 JST)

- Command: as above
- CLI versions: codex-cli `0.130.0`, plugin `1.0.4`, Claude Code `2.1.137`
- `~/.codex/config.toml` model: `gpt-5.5`
- Outcome: rc=0, elapsed=86s, adv.md=2,397 bytes, adv.err=977 bytes
- Classification: **SUCCESS**
- adv.err tail: `[codex] Turn completed.`
- adv.md excerpt: `Verdict: needs-attention` + 2 [high] findings (CLAUDE.md symlink risk + structured fact source missing) + recommendations + next steps
- #305 signature: not detected (no `Invalid value` / `unknown_parameter` / `gpt-5.5 requires` strings in adv.err)

→ **`--model gpt-5.4` pin remains functional on local CLI 0.130.0 today.** option (d) (`gpt-5.3` rolling-forward) is therefore unnecessary; Issue #193 proceeds with the original Stage 1/2 plan.

### Note on duration

86s is short compared to the 2026-05-06 work-dir log baseline (3-7 min for typical `triple-review` runs). This is expected: probe diff = this branch's committed change is small (probe log + ADR 0021 + ADR 0012 patches), versus the multi-hundred-line PR diffs the 5/6 logs reviewed. Real-review structural integrity confirmed via the `Verdict / Findings / Recommendations / Next steps` shape and the `Turn completed.` epilogue.

### Codex finding adoption

Codex flagged 2 [high] issues during this probe; both are adopted into the ADR 0021 design:

1. **probe command lacked timeout wrapper documentation** → `perl alarm 600` wrapper now explicit in the command block above.
2. **workaround path success used as revert decision basis (false confidence)** → ADR 0021 separates Step 0a (workaround path) from Stage 1 (revert path) conceptually; both are required.

## Stage 1 — model unpin probe

### Stage 1 probe (2026-05-10 19:18:17 — 19:20:12 JST)

- Command: `perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!"' 600 node "$CODEX_COMPANION" adversarial-review --base main --scope branch > "$LOGDIR/adv.md" 2> "$LOGDIR/adv.err"` (no `--model`; relies on `~/.codex/config.toml` default)
- CLI versions: codex-cli `0.130.0`, plugin `1.0.4`, Claude Code `2.1.137`
- `~/.codex/config.toml` model: `gpt-5.5` (unchanged from ADR 0012 / Step 0a)
- Outcome: rc=0, elapsed=115s, adv.md=1,319 bytes, adv.err=3,366 bytes
- Classification: **SUCCESS** (unexpected — ADR 0021 / Plan A.1 期待値は < 5%)
- adv.err tail: `[codex] Turn completed.`
- adv.md excerpt: `Verdict: needs-attention` + 1 [high] finding — Codex flagged the Step Z `cleanup` subcommand bug in HEAD `dc91550` (the fix lands in this same commit; Codex sees committed state only).
- Step Z post-cleanup: rc=0 (broker teardown OK; pre-existing ghost job state from past runs persists, outside helper scope)
- #270 re-check (per Plan A.1 recommendation when SUCCESS observed): still `open` as of 2026-05-10 (last activity 2026-04-26, no new comments) → local CLI 0.130.0 + plugin 1.0.4 simply does not reproduce the upstream `gpt-5.5` default regression. The workaround was correct for its environment, but the environment changed.

## Stage 2 — slash-dispatch probe

### Stage 2 probe (2026-05-10 20:32:03 — 20:34:23 JST)

- Command: `perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!"' 600 claude -p --settings '{"outputStyle":"triple-review"}' "/codex:adversarial-review --wait --base main --scope branch" > "$LOGDIR/adv.md" 2> "$LOGDIR/adv.err"`
- CLI versions: codex-cli `0.130.0`, plugin `1.0.4`, Claude Code `2.1.137`
- `~/.codex/config.toml` model: `gpt-5.5`
- Outcome: rc=0, elapsed=140s, adv.md=1,272 bytes, adv.err=157 bytes
- Classification: **SUCCESS** (unexpected — Plan A.3 期待値は #183 hang likely)
- adv.err tail: `Warning: no stdin data received in 3s, proceeding without it.` (claude -p stdin warning のみ; `[codex]` progress lines は claude session transcript 側に行くので stderr には出ない)
- adv.md excerpt: `Verdict: needs-attention` + 1 [high] finding — Stage 1 と同じ probe-log Step Z bug を flag (HEAD `dc91550` 視点で正しい指摘)
- Step Z post-cleanup: rc=0 (broker teardown OK)
- #183 (captureTurn await forever) status: still open as of 2026-05-09 + PR #184 unmerged → local Claude Code 2.1.137 + plugin 1.0.4 が `--wait` を hang させない理由は不明だが、両 workaround の動機 (#270 + #183) はいずれも本日のローカル環境で再現していない事実が決定的。
- Quote scheme observation: `--base main` 直書きで成立 → production code (option (a1)) は `--base "$base"` quoted form で問題なし (bash variable expansion は claude が受け取った 1 引数を内部 parse する前に展開される)。

## Decision (2026-05-10 initial; superseded by Stage 3 / 3b on 2026-05-11)

Stage 1 SUCCESS + Stage 2 SUCCESS → **option (a1) 暫定採用** (full revert: slash dispatch 復活 + `--model gpt-5.4` pin 撤去)。`autoUpdate: false` は ADR 0012 §"Workaround" の `broker cleanup helper の plugin internal API 依存性` を別途解消するまで維持 (option (a2) の eligibility gate)。詳細と decision rationale は ADR 0021 §"Status" Revision (2026-05-10) を参照。

**この決定は 2026-05-11 の Stage 3 (dogfood) + Stage 3b (disambiguating probe) で覆る (下記)。最終 Decision は option (c) (workaround retain) で、ADR 0021 §"Status" Revision (2026-05-11) を参照。**

## Stage 3 — production-scale dogfood (option (a1) を triple-review 経由で自己検証)

option (a1) (Stage 1/2 SUCCESS で暫定採用、PR #194 で実装) の production-scale 動作を確認するため、PR #194 自身に `triple-review` を 3 試行実走。

### Stage 3 dogfood runs (2026-05-11)

| Run | OS | 開始時刻 (JST) | ADV 経過 | `adv.err` | `adv.md` | 結末 | プロセスツリー観察 |
|---|---|---|---|---|---|---|---|
| 1 | macOS (Apple Silicon) | 12:18 | 37m+ `run` | 0 bytes | 0 bytes | 手動 Ctrl+C | (Run 2 で詳細採取) |
| 2 | macOS (Apple Silicon) | 13:36 | 31m28s `run` | 0 bytes | 0 bytes | 手動 Ctrl+C | `claude -p` → zsh `node codex-companion.mjs adversarial-review …` → `app-server-broker.mjs` → `codex app-server` が **約 3 min warm-up 後に正常 spawn**。spawn 後 30 分弱の間、stdout/stderr 双方無音 |
| 3 | Linux (Ubuntu) | (時刻別環境) | 59m21s `run` | 0 bytes | 0 bytes | 手動 Ctrl+C | (Run 2 と同形のツリーが spawn される観察、本 host でも再現) |

**Classification (全 3 試行)**: rc=130 (SIGINT)。`classify_stage1` を流用すれば `HANG` 相当 (wall-time は `perl alarm` 上限を遥かに超過した手動中断)。

**初期仮説**: ADR 0021 が Stage 2 SUCCESS を 140s / 小規模 diff で確認していたことから、「production-scale diff (PR #194: +375/-109) で `captureTurn` await を踏み抜けるサイズ閾値を越えた」と推定。`#183` (captureTurn await forever) の単純な scale-dependent 再現と仮定。

**仮説検証ステップ → Stage 3b へ**: scope 単独起因か、wrapper 介入の interaction か、を切り分けるため disambiguating probe を実施 (下記)。

### Stage 3 cleanup

各 run の後、`kill_children` EXIT trap で codex-companion / app-server-broker / codex app-server が reap されることを確認。Run 1 の終了後、Run 2 の直前に `ps aux | grep 'app-server'` / `pgrep codex` で orphan 不在を確認 (clean retry のため)。

## Stage 3b — disambiguating probe (wrapper bypass, 2026-05-11)

Stage 3 hang が「diff scope 起因」か「wrapper interaction 起因」かを切り分けるため、Linux 環境で PR #194 branch 上で **`triple-review` script (`claude_p_neutral` wrapper) を bypass** し、`claude -p` を直接実行する probe を 1 回実施。

### Stage 3b probe

```bash
cd ~/.local/share/chezmoi
git checkout feat/triple-review-adv-revert-probe  # PR #194 head (36ce93e)
git status  # working tree clean を確認
perl -e 'alarm 1200; exec @ARGV' \
  claude -p '/codex:adversarial-review --wait --base main --scope branch'
```

- Command: 上記 (`perl alarm 1200` でハードキャップ、`--settings` 不使用)
- Environment: PR #194 head (`36ce93e`)、Linux、codex-cli `0.130.0` + plugin `1.0.4` + Claude Code `2.1.137`
- Outcome: **SUCCESS**。real adversarial review が完走 (構造化された Verdict / Findings / Recommendations 含む)
- Classification: **SUCCESS**

### adv.md excerpt (Stage 3b)

```
# Codex Adversarial Review

Target: branch diff against main
Verdict: needs-attention

No-ship: the ADV revert depends on a locally tested slash-dispatch path but ships it unconditionally, with no guard for the known hanging versions/environments.

Findings:
- [high] Unconditional ADV slash dispatch can reintroduce the headless hang (dot_local/bin/executable_triple-review:920-921)
  The ADV leg now always runs through `claude_p_neutral "/codex:adversarial-review --wait ..."`.
  ... There is no minimum-version check, runtime probe, timeout, or fallback to the direct
  companion path, so another managed host with the older or still-affected Claude/Codex
  environment can hang the pipeline after PR/SEC reviewers have already been launched and paid for.
  Recommendation: Do not make slash dispatch unconditional. Add a bounded ADV timeout plus
  fallback to the direct `codex-companion` invocation, or fail fast behind an explicit
  version/preflight gate that proves the installed Claude/Codex stack is in the known-good set
  before spawning reviewers.

Next steps:
- Add a regression test that simulates a hanging ADV slash command and verifies `triple-review`
  exits or falls back within a bounded time.
- Gate the new path on a checked Claude/Codex/plugin version or preserve the old direct-companion
  path as the failure-mode fallback.
```

### Stage 3b 解釈

| 試行 | wrapper (`--settings`) | `--wait` | diff scale | 結果 |
|---|---|---|---|---|
| Stage 0a | ✗ (bare CLI) | ✗ | 小 | SUCCESS |
| Stage 1 | ✗ (bare CLI) | ✗ | 小 | SUCCESS |
| Stage 2 | ✓ | ✓ | 小 | SUCCESS |
| Stage 3 | ✓ | ✓ | 大 (PR #194) | **HANG** (3-of-3) |
| Stage 3b | ✗ | ✓ | 大 (PR #194) | SUCCESS |

**含意**:

1. **scope 単独は原因ではない** — Stage 3b で wrapper bypass + production-scale diff が SUCCESS。`#183` の単純 scale-dependent 再現仮説 (Stage 3 直後の初期仮説) は棄却。
2. **wrapper 単独も原因ではない** — Stage 2 で wrapper + `--wait` 環境でも小規模 diff なら SUCCESS。output-style 注入そのものが壊れているわけではない。
3. **3 因子 AND が必要条件**: `claude_p_neutral` wrapper (`--settings '{"outputStyle":"triple-review"}'`) + `/codex:adversarial-review --wait` + production-scale diff。全て同時成立した時のみ発症する narrow failure mode。
4. **PR/SEC が同 wrapper で完走する内部一貫性**: PR / SEC は `--wait` 不使用のため、3 因子 AND の `--wait` 条件が欠ける → 完走。

### Codex self-finding ([high]) の独立 valid 性

Stage 3b probe で取得した Codex review は本 PR #194 (option a1) を **adversarial review 自身が `[high]` で flagging**。これは本 investigation の wrapper × scale interaction issue とは別軸の指摘で、「Claude/Codex 環境 version 依存性を unconditional ship してはいけない」という指摘 (bounded timeout + fallback OR explicit version gate)。本 PR の option (c) 採用で sidestep 済だが、re-investigation 時には必須検討事項。

## Final Decision (2026-05-11)

3 因子 AND の hang condition が production-scale ADV で実発症する以上、**option (a1) は reject**。`main` の bare-CLI + `--model gpt-5.4` pin を **option (c)** として retain。ADR 0021 §"Status" Revision (2026-05-11) で正式記録。PR #194 は本決定で superseded、新 PR で investigation 成果物 (本 probe log + ADR 0021 + ADR 0012 Status revision + silent-degradation fix 等) を ship する。

## Step Z — probe cleanup

Run after each Stage probe to clear orphan broker / ghost job state introduced by bare-CLI invocation (cf. ADR 0012 §"Known side effect").

```bash
# Broker cleanup helper (same one triple-review uses).
# `teardown` is the only public subcommand alongside `snapshot`; the helper
# has no standalone `cleanup` form. Forcing existed:false skips the
# conservative no-op branch so probe brokers (which were not pre-snapshotted)
# are torn down unconditionally.
node "$HOME/.local/bin/triple-review-broker-cleanup" teardown "$PWD" '{"existed":false}' 2>&1 || true

# Ghost job state inspection (manual)
ls ~/.claude/plugins/data/codex-openai-codex/state/*/jobs/ 2>/dev/null | head
```

If the helper is unavailable or degrades silently, fall back to ADR 0012 §"Known side effect" — "Manual cleanup if the helper degrades silently".
