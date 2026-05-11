# ADR 0021: triple-review ADV leg revert investigation (Issue #193)

## Status

Accepted (2026-05-09, revised 2026-05-10, 2026-05-11).

**Revision (2026-05-10, post Stage 1/2 probes)**: Stage 1 (model unpin) と Stage 2 (slash dispatch) の両 probe が SUCCESS で完了 — 両 workaround の動機 (upstream `openai/codex-plugin-cc#270` + `#183`) はいずれも本日のローカル環境 (codex-cli `0.130.0` + plugin `1.0.4` + Claude Code `2.1.137`) で再現せず。**option (a1) 暫定採用**: `dot_local/bin/executable_triple-review:917-927` を `claude_p_neutral "/codex:adversarial-review --wait --base \"$base\" --scope branch"` に置換し、`--model gpt-5.4` pin と direct codex-companion bypass を同時撤去。`private_dot_claude/settings.json:188` の `autoUpdate: false` は ADR 0012 §"Workaround" の broker cleanup helper plugin-internal-API 依存性 (Issue #163) を別途解消するまで維持 — option (a2) は本 Issue では eligibility gate を満たさず deferred。Stage 1 SUCCESS は upstream `#270` still open 状態と矛盾するが `gh api` 再確認で state 不変を確認済 (last activity 2026-04-26)。Stage 2 SUCCESS も `#183` open + PR `#184` unmerged 状況と矛盾するが、本ローカル環境では hang 再現せず — workaround は導入時環境で正しかったが環境が変わった。両 probe transcripts は `docs/issues/193-probe-log.md` Stage 1/2 sections 参照。

**Revision (2026-05-11, post Stage 3 dogfooding + Stage 3b disambiguating probe)**: option (a1) **REJECTED**。Stage 3 (option (a1) を適用した PR #194 自身への `triple-review` self-dogfood, 3 試行 = macOS×2 + Linux×1) で ADV leg が 31-59min `--wait` 状態で hang し `adv.err` 0 bytes。**初期仮説 (probe scope 単独起因) は Stage 3b の disambiguating probe で棄却** — wrapper bypass で `claude -p '/codex:adversarial-review --wait --base main --scope branch'` を PR #194 full diff に対し直接実行したところ **SUCCESS** が返り、real adversarial review (Codex 自身が PR #194 を `[high]` で flagging する内容) を含む完走を確認。**真の hang 条件は 3 つの AND**: (1) `claude_p_neutral` wrapper (`--settings '{"outputStyle":"triple-review"}'`) + (2) `/codex:adversarial-review --wait` + (3) production-scale diff の 3 因子すべて同時成立で初めて発症。証拠: **Stage 2** (wrapper ✓ / `--wait` ✓ / 小規模 diff ✗) → SUCCESS、**Stage 3b** (wrapper ✗ / `--wait` ✓ / 大規模 diff ✓) → SUCCESS、**Stage 3** (3 条件全て ✓) → HANG。PR/SEC が同 wrapper で完走するのも `--wait` 条件が欠ける (`/pr-review-toolkit:review-pr` / `/security-review` は `--wait` 不使用) ためで、内部一貫性あり。Stage 3b probe transcript は `docs/issues/193-probe-log.md` Stage 3b section 参照。**最終決定は option (c) (workaround retain)**: `main` の bare-CLI + `--model gpt-5.4` pin を維持、ADR 0012 §"Workaround" / §"Known limitation" の Status は "investigation completed 2026-05-11 — retained per Stage 3" に書き直し。option (a1) を実装した PR #194 の experimental commits (`9a8aa9b` / `abe3e89` / `d1279fb` / `36ce93e`) は dogfooding 結果と共に supersede され close。**併せて Codex review 自身が (a1) を `[high]` で指摘**: "unconditional ADV slash dispatch can reintroduce the headless hang … no minimum-version check, runtime probe, timeout, or fallback" — bounded ADV timeout + fallback to direct codex-companion、または explicit version/preflight gate を推奨。本観点は (c) 採用で sidestep 済だが、follow-up Issue として Issue #189 (per-leg timeout) と新規 "investigate wrapper × `--wait` × scale hang" を分離 file する。Re-investigation は (i) upstream `#270` + `#183` の close、(ii) wrapper interaction の root cause 解明、(iii) target-PR 規模での **wrapper-aware** dogfood gate (本 ADR の Done 判定基準に追加) の 3 条件成立後にトリガする。

This ADR records the investigation framework, the Step 0a smoke-test result, and the decision tree used to choose between revert options. The decision evolved through three Status revisions following the ADR 0020 pattern: Stage 1/2 probes (2026-05-10) gave option (a1) a tentative SUCCESS, then Stage 3 production dogfooding + Stage 3b disambiguating probe (2026-05-11) flipped the verdict to **REJECTED** and selected option (c) (workaround retain). Future Stage-N probes against the 4 re-investigation triggers (§Status Revision 2026-05-11) will be appended as further `**Revision (...)**` paragraphs.

## Context

ADR 0012 §"Workaround — direct codex-companion invocation" と §"Known limitation — codex plugin model default broken on codex-cli 0.125.0 + plugin 1.0.4" は、2026-04-22 当時の `codex-cli 0.125.0` + `plugin 1.0.4` + Claude Code 2.1.116 の環境で導入された 2 つの workaround を記録している:

- **slash-dispatch bypass**: `claude -p "/codex:adversarial-review --wait …"` が headless で `phase: starting` hang するため、`node $CODEX_COMPANION adversarial-review …` を直叩き
- **model pin**: default `gpt-5.5` が plugin 経由で 400 を返すため `--model gpt-5.4` で固定

Issue #193 は 2026-05-09 時点での revert 可能性を verify する目的で起票された。投資的調査 (Plan の Stage 1 → 2 → 3 → 4) を実走する前に、上流状況の再確認 + 現環境での workaround 健在性確認が必要だった。

### Step 0 (upstream snapshot, 2026-05-09)

| Issue | State | Last activity |
|---|---|---|
| `openai/codex-plugin-cc#270` (gpt-5.5 default broken) | open | 2026-04-26 |
| `openai/codex-plugin-cc#183` (captureTurn await forever) | open | 2026-04-08 |
| `openai/codex-plugin-cc#305` (gpt-5.4 + gpt-5.5 reject `tools: 'custom'`) | closed 2026-05-08 (`"filing in our internal tracker"`) | 2026-05-08 |

`#305` は本投資的に新規発見。「CLI 0.128.0+ で `--model gpt-5.4` も `unknown_parameter` で 400 を返すよう regression が広がった」と報告 → ローカル `codex-cli 0.130.0` (`#305` reporter 環境よりさらに新しい) で `--model gpt-5.4` pin 自体が壊れている可能性が浮上し、option (d) (`gpt-5.3` ロールフォワード) の緊急性を検討する必要が生じた。

### Step 0a (smoke test result, 2026-05-09 17:55:13 — 17:56:39 JST)

`#305` 由来の懸念を解消するため、現 workaround 構成 (`--model gpt-5.4` pin) で bare CLI smoke test を実走:

- **Command**: `perl -e 'alarm 600; exec @ARGV' node "$CODEX_COMPANION" adversarial-review --base main --scope branch --model gpt-5.4 > $LOGDIR/adv.md 2> $LOGDIR/adv.err`
- **Environment**: codex-cli `0.130.0`, plugin `1.0.4`, Claude Code `2.1.137`, `~/.codex/config.toml` model `gpt-5.5`
- **Outcome**: rc=0, elapsed 86s, adv.md 2,397 bytes, adv.err 977 bytes
- **Classification**: SUCCESS (real review with `Verdict: needs-attention` + 2 [high] findings + recommendations; adv.err ends with `[codex] Turn completed.`)
- **#305 signature**: `Invalid value: 'custom'` / `unknown_parameter` 検出なし

→ ローカル CLI 0.130.0 では `--model gpt-5.4` pin は依然機能している。**option (d) (gpt-5.3 ロールフォワード) の緊急性は消失。Issue #193 元 Plan (Stage 1/2 → option a/b/c) で進む。**

なお Codex 自身が smoke test 中に probe log の脆弱性 2 件を [high] で指摘した (timeout/alarm wrapper 文書化漏れ + workaround path success が revert 判断の root false confidence)。両指摘は本 ADR の設計に組み込み済 (probe log の `perl alarm` 明示 / Step 0a と Stage 1 の概念分離)。

### Step 0a の解釈 (R14)

Step 0a SUCCESS は「現 workaround が 2026-05-09 時点で機能している」事実を示すのみ。これは workaround 維持の根拠でも revert の根拠でもなく、**Stage 1/2 probe で revert path の動作可否を独立に検証する** 必要がある。

### Step 3 (Stage 3 dogfood result, 2026-05-11)

Stage 1/2 probe SUCCESS の信頼性を実 production scale で検証するため、option (a1) を適用した PR #194 自身に `triple-review` を実走 (3 試行):

| 試行 | 環境 | ADV 経過 | `adv.err` | `adv.md` | 結末 |
|---|---|---|---|---|---|
| Run 1 | macOS (Apple Silicon) | 37m+ `run` | 0 bytes | 0 bytes | 手動 Ctrl+C |
| Run 2 | macOS (Apple Silicon) | 31m28s `run` | 0 bytes | 0 bytes | 手動 Ctrl+C |
| Run 3 | Linux (Ubuntu) | 59m21s `run` | 0 bytes | 0 bytes | 手動 Ctrl+C |

**3-of-3 hang。Run 2 のプロセスツリー analysis** で `codex-companion` + `app-server-broker` + `codex app-server` は `claude -p` 起動から約 3 min warm-up 後に正常 spawn されることを確認 — つまり hang ポイントは slash dispatch 層 (旧 `phase: starting` symptom) ではなく、codex-companion 内部の `--wait` mode の codex broker 通信段階で発生している。

**初期仮説 (diff scope 起因) と Stage 3b による棄却**: 当初は「Stage 2 probe (140s SUCCESS) は probe branch の小規模 diff で hang 条件を踏まなかった」と推定した。これは `#183` (captureTurn await forever) の挙動と整合する仮説だったが、Stage 3b の disambiguating probe で **棄却された** (詳細は次節)。

**Classification**: 全 3 試行とも `classify_stage1` を流用すれば `HANG` 相当 (rc=130 / SIGINT。wall-time が `perl alarm 600` の上限を遥かに超過しているため意図的中断による HANG 確定)。

### Step 3b (Disambiguating probe — wrapper bypass, 2026-05-11)

Stage 3 hang の原因が「diff scope 起因」か「wrapper interaction 起因」かを切り分けるため、Linux 環境で PR #194 branch を checkout したまま **`claude_p_neutral` wrapper を bypass** して直接 `claude -p` で probe を実行:

- **Command**: `perl -e 'alarm 1200; exec @ARGV' claude -p '/codex:adversarial-review --wait --base main --scope branch'`
- **Environment**: PR #194 head (`36ce93e`)、Linux、codex-cli `0.130.0` + plugin `1.0.4` + Claude Code 2.1.137
- **Outcome**: **SUCCESS**。real adversarial review を完走 (`# Codex Adversarial Review` heading + `Verdict: needs-attention` + 構造化 findings 含む)
- **Codex 自身の self-finding ([high])**: 本 probe で得た review 内に「`[high] Unconditional ADV slash dispatch can reintroduce the headless hang (dot_local/bin/executable_triple-review:920-921)` … no minimum-version check, runtime probe, timeout, or fallback to the direct companion path」という形で **PR #194 (option a1) を独立に flag**。"Add a bounded ADV timeout plus fallback to the direct `codex-companion` invocation, or fail fast behind an explicit version/preflight gate" を推奨。

**含意 (factor matrix 全 4 セルの解釈)**:

| | small diff (probe-size) | large diff (PR #194 scale) |
|---|---|---|
| **wrapper + `--wait`** | Stage 2: SUCCESS | Stage 3: **HANG** |
| **no wrapper + `--wait`** | (未実施 — Stage 0a/Stage 1 は bare CLI で `--wait` 不使用) | Stage 3b: SUCCESS |

1. **scope 単独は原因ではない** — Stage 3b で production-scale diff でも wrapper なしなら SUCCESS。`#183` captureTurn-await-forever の単純再現ではない。
2. **wrapper 単独も原因ではない** — Stage 2 で wrapper + `--wait` 環境でも小規模 diff なら SUCCESS。output-style 注入そのものが壊れているわけではない。
3. **真の hang 条件は 3 因子 AND**: `claude_p_neutral` wrapper (`--settings '{"outputStyle":"triple-review"}'`) + `/codex:adversarial-review --wait` + production-scale diff。3 つすべて同時成立した時のみ発症。output-style によるシステムプロンプト置換が、`--wait` mode の codex broker streaming において **diff 規模が大きい時にのみ顕在化する completion marker / streaming protocol** に副作用を与えていると推定。
4. **PR/SEC が同 wrapper で完走する内部一貫性**: PR (`/pr-review-toolkit:review-pr`) と SEC (`/security-review`) は `--wait` mode を使わないため、wrapper × `--wait` × scale の 3 者 interaction を triggering せず正常完走する。よって wrapper 自体が壊れているのではなく、3 因子 AND が成立した時にのみ発症する narrow failure mode。
5. **Codex の self-finding は path 独立に valid な指摘**: `[high]` の "unconditional ship するな" 勧告は (a1) の wrapper interaction issue とは別軸で、Claude/Codex 環境 version 依存性そのものを安全装置で囲うべきという指摘。本 PR の (c) 採用で sidestep 済だが、再投資時には timeout + fallback または version gate を検討すべき。

**Decision**: option (a1) **REJECTED**。原因は probe configuration ≠ prod configuration (wrapper layer + scale の 2 軸で同時に乖離していた)。Re-investigation 条件: (i) upstream `#270` + `#183` の close、(ii) **wrapper × `--wait` × scale interaction の root cause 解明** (output-style × `--wait` × codex broker の挙動)、(iii) wrapper-aware かつ production-scale な dogfood gate (本 ADR §"Done 判定基準" に追加) が満たされること、(iv) 並行して Issue #189 (per-leg timeout) reconcile で `--wait` hang を fail-loud 化する仕組みが landed されること。

## Decision

### 判断ツリー

```text
Step 0a smoke test (gpt-5.4 pin)        [DONE: SUCCESS rc=0 86s]
                  v
Step 0c uncommitted 退避                [DONE: 別 worktree に逃し、本 branch は clean]
                  v
Step 0b probe log 修正                  [本 ADR と同 commit で実施]
                  v
Step 1: Stage 1 probe (model unpin)
   perl -e 'alarm 600; exec @ARGV' \
     node $CODEX_COMPANION adversarial-review --base main --scope branch
   (--model 抜き = config.toml default gpt-5.5)
                  |
       +----------+----------+----------+----------+
       SUCCESS    HANG       400        SANDBOX    SILENT
       |          (rc=124)   (#270)     (env)      (rc=0+empty)
       v          v          v          v          v
    Step 2     option(c)  option(c)  MANUAL     option(c)
                                     TRIAGE
                                     (env fix)
       v
Step Z probe cleanup                    (broker / ghost job state)
       v
Step 2: Stage 2 probe (slash dispatch)  [Stage 1 SUCCESS のみ]
   perl -e 'alarm 600; exec @ARGV' \
     claude -p "/codex:adversarial-review --wait \
       --base main --scope branch"
                  |
       +----------+----------+
       SUCCESS               FAIL (hang/error)
       v                     v
    option (a1) / (a2)    option (b)
       v                     v
Step Z probe cleanup
```

### 4 option (final)

| option | `executable_triple-review` | bats T3-7 | `private_dot_claude/settings.json` | `~/.codex/config.toml` | 適用条件 |
|---|---|---|---|---|---|
| **(a1)** | slash dispatch (`claude_p_neutral "/codex:adversarial-review --wait …"`) に置換 | grep を slash 形に書き換え | `autoUpdate: false` 維持 | 変更なし | Stage 2 SUCCESS。broker cleanup helper の plugin internal API 依存を保全 |
| **(a2)** | (a1) と同じ | (a1) と同じ | `autoUpdate: true` 復活 | 変更なし | (a1) 条件 + broker cleanup helper を別 Issue で deprecate / 別 strategy に置換する判断済 |
| **(b)** | `--model gpt-5.4` 削除のみ | `--model gpt-5.4` grep 行削除 | 変更なし | `model = "<動く model>"` に変更 (bundle 必須) | Stage 1 SUCCESS + config.toml 変更承認。変更先 model の smoke test SUCCESS 必須 (`gpt-5.4` 採用なら Step 0a で代用可、別 model なら新規 probe 必須) |
| **(c)** | 変更なし | 変更なし | 変更なし | 変更なし | Stage 1/2 FAIL (workaround 維持必要) |

(a1) を default 推奨とする。(a2) は ADR 0012 §"Known side effect" / §"Workaround" の `autoUpdate: false` 動機 (broker cleanup helper の API drift 防止) を別途解消した上で初めて選択可能。

### Stage 1 result classifier

Stage 1 probe 出力を以下の bash 関数で SUCCESS / HANG / 400 / SANDBOX / SILENT / OTHER に分類する:

```bash
classify_stage1() {
  local rc="$1" adv_md="$2" adv_err="$3"
  case "$rc" in
    0)
      if [ "$(wc -c < "$adv_md")" -lt 200 ] || \
         grep -qF 'Codex のレビューがまだ進行中' "$adv_md"; then
        echo SILENT
      else
        echo SUCCESS
      fi
      ;;
    124|142) echo HANG ;;
    *)
      if grep -qE "Invalid value|unknown_parameter|gpt-5.5 requires" "$adv_err"; then
        echo 400
      elif grep -qE "EROFS|EPERM|sandbox|denied" "$adv_err"; then
        echo SANDBOX
      else
        echo OTHER
      fi
      ;;
  esac
}
```

`OTHER` は `MANUAL TRIAGE` 経路に合流する。

### Probe result template

各 Stage 結果を `docs/issues/193-probe-log.md` に同一 schema で記録する:

```markdown
### Stage N probe (YYYY-MM-DD HH:MM:SS)

- Command: `<exact bash with perl alarm wrapper>`
- CLI versions: codex-cli X.Y.Z, plugin X.Y.Z, Claude Code X.Y.Z
- ~/.codex/config.toml model: <value>
- Outcome: rc=N, elapsed=Ns, adv.md size=N bytes
- Classification: {SUCCESS | HANG | 400 | SANDBOX | SILENT | OTHER}
- adv.err tail (last 20 lines): <excerpt>
- adv.md excerpt (first 30 lines or full if short): <excerpt>
```

### Probe scope (R13)

Stage 1/2 probe diff = 本 branch の committed diff のみ (probe log + 本 ADR + ADR 0012 加筆 = 数十行)。実 production scale の検証は本 ADR の範囲外であり、option 採用後の次回 `triple-review` 実走で間接確認する。Stage 1/2 は「workaround unpin で動くか?」の二値判定が目的なので薄い diff で十分。

### Done 判定基準

- [x] Step 0a 結果記録 (smoke test SUCCESS rc=0 86s) — 2026-05-09
- [x] Step 1 (Stage 1 probe) 実走 + 結果分類 (**SUCCESS** rc=0 115s; commit `56ac207`)
- [x] Step Z (probe cleanup) 実走 (`teardown ... '{"existed":false}'` 形, rc=0; commit `56ac207`)
- [x] Step 2 (Stage 2 probe) 実走 + 結果分類 (**SUCCESS** rc=0 140s; commit `56ac207`)
- [x] option **(a1)** 暫定採用 + 採用理由を Status revision に記録 (commit `56ac207`; 後に Stage 3 で REJECTED)
- [x] Step 3 (Stage 3 dogfood) 実走 (3-of-3 ADV hang, 31-59min, 全試行 `adv.err` 0 bytes; PR #194 history で記録) — 2026-05-11
- [x] option (a1) **REJECTED** 判定 + 却下理由を Status revision に記録 (2026-05-11)
- [x] option **(c)** (workaround retain) 採用 + ADR 0012 §"Workaround" / §"Known limitation" Status を "retained per Stage 3" に書き直し
- [-] (option (b) 採用時) — N/A: option (c) 最終採用のため不要
- [-] (option (a1) 採用時の bats T3-7 / Docker parity 検証) — N/A: REJECTED により main の bare-CLI contract 維持、production code 変更なし
- [x] Re-investigation トリガ条件を明示 (upstream `#270` + `#183` close, target-PR 規模の dogfood gate, Issue #189 timeout reconcile) — Status revision 2026-05-11 に記録

※ 必須ゲート (動作検証・既存機能・差分確認・シークレット) は常に適用。

### 次回 investigation の Done 判定基準への教訓 (Stage 3 + 3b 由来)

本 investigation の **最大の方法論的欠陥** は probe configuration (wrapper / scope) と prod configuration の乖離を **2 軸同時に未検証で残した** こと。Stage 2 は wrapper を含んだが scope が小、Stage 1 / Step 0a / Stage 3b は scope を満たしたが wrapper を欠いた。3 因子 AND (wrapper + `--wait` + production-scale) の hang condition を本 investigation の design で意識的に踏みに行く gate が無かった。次回類似の `--wait` / hang 系 revert investigation には以下を Done 判定基準として追加する:

- [ ] **wrapper-aware × production-scale dogfood gate (合算)**: probe は最終的に **production と同じ wrapper / settings / output-style 経由 × target PR 規模 (100+ 行) の diff** で 1 回以上実走する。wrapper-only probe (Stage 2 形) と scale-only probe (Stage 3b 形) のいずれも単独では production を代表しない。両条件 AND を満たす形で実走、ADV / SEC / PR 全 leg の正常完走を確認 — 個別 probe SUCCESS で採用判断しない
- [ ] (optional) 複数 OS でクロス検証 (macOS + Linux) — environment-specific hang を早期検出

### Lessons learned (Phase A-C 完了後に追記)

Stage 1/2 が予想 (期待値 < 5%) を裏切って **両方 SUCCESS** だった点は本 investigation の最大の発見。以下が次回類似 investigation での教訓:

1. **Workaround は環境固有 (ただし path-dependent)**: ADR 0012 workaround は codex-cli `0.125.0` + plugin `1.0.4` + Claude Code `2.1.116` 環境で必要だったが、CLI / Claude Code が version up した後 (それぞれ `0.130.0` / `2.1.137`) では **probe path (wrapper なし `claude -p` 直接) では再現せず**。Upstream issue (#270 / #183) が依然 open であっても、ローカル環境固有の要因 (CLI 内部の path 変更等) で probe path 範囲内では解消したように見えることがある。**Upstream resolution を待つだけでなく、定期的に local probe で revert 可能性を verify する** 価値はある — ただし Stage 3 で判明した通り **probe SUCCESS は採用根拠としては不十分** で、wrapper-aware path での dogfood が必須 (下記 #4 参照)。
2. **Codex finding 採用 (probe log 内 cleanup → teardown bug)**: Step 0a / Stage 1 / Stage 2 すべての adv.md で Codex が同一の bug ([high]) を flag した。adversarial review が high-priority issue を robust に検出する能力を実例で確認。本 investigation の probe log 修正は Codex 自身の指摘から逆算で出てきた経緯。
3. **bats negative pin の重要性**: T3-7 の `! grep -F -- '--model gpt-5.4'` は当初コメント内 literal も誤検出した (bats fail)。コメントから literal `--model gpt-5.4` を削除して resolve。grep ベースの negative pin はコメントも match するので、source code 内に literal を残す場合は context 区別を考慮する必要あり。

### Lessons learned (Stage 3 + 3b 追記 2026-05-11)

Stage 1/2 SUCCESS が Stage 3 で全試行 hang に転じ、Stage 3b の disambiguating probe で「diff scope 起因」仮説が棄却された事実から、本 investigation 自体の方法論的欠陥が 4 つ判明:

4. **probe configuration ≠ prod configuration が false positive を許す (2 軸の同時乖離)**: Stage 2 は production と同じ wrapper (`--settings '{"outputStyle":"triple-review"}'`) を使用したが diff scope が小規模だった。production-scale + wrapper-aware の dogfood は本 investigation の Done 判定基準に含まれていなかった。Stage 3 で初めて 3 因子 AND を踏み hang を観測、Stage 3b で wrapper bypass による disambiguation を実施して「scope 単独でも wrapper 単独でもない、3 因子 AND が必要」と確定。R13 (Probe scope) は scope のみを論点としていたが、**probe path (wrapper layer) も同時に論点とすべきだった**。次回 similar investigation の Done 判定基準には「wrapper-aware × production-scale dogfood gate」を必須項目に追加する (上記 §"次回 investigation の Done 判定基準への教訓" 参照)。
5. **`#183` hang は narrow な 3 因子 AND condition で再現する**: Step 0a (bare CLI + `--model gpt-5.4`) は SUCCESS、Stage 1 (bare CLI / `--model` unpin) も SUCCESS、Stage 2 (wrapper + `--wait` / 小規模) **も SUCCESS**、Stage 3b (wrapper bypass / `--wait` / production scale) **も SUCCESS**。Stage 3 (wrapper + `--wait` + production scale) **のみ hang**。よって upstream `#183` (captureTurn await forever) は本環境では **`claude_p_neutral` 形 wrapper + `--wait` + 100+ 行 diff** の 3 条件すべて同時成立した時のみ再現する。Upstream issue にこの観測を追加報告する価値あり (reproduction recipe: `--settings` JSON + `--wait` + 大 diff の AND、bare CLI / wrapper bypass / `--wait` なしいずれかが欠けると非再現)。
6. **`--wait` の per-leg timeout 不在が silent degradation を許す**: 31-59min の hang を「待つしか無い / 手動 Ctrl+C しか手段がない」状況自体が、`triple-review` 設計の missing piece。Issue #189 (per-leg timeout 480s) の reconcile が再認識された (separate concern、別 Issue で追跡)。
7. **Codex 自身の self-finding を investigation の 1 階層 high-confidence signal として扱う**: Stage 3b で取得した Codex review は本 PR #194 (option a1) を **独立に `[high]` で flagging** した ("Unconditional ADV slash dispatch can reintroduce the headless hang … no minimum-version check, runtime probe, timeout, or fallback")。これは本 investigation の hang 観察とは別軸の指摘 (環境 version 依存性の安全装置不在) で、Codex 推奨の "bounded timeout + fallback to direct codex-companion / explicit version gate" は path 独立に valid。本 PR は (c) 採用で sidestep したが、再投資時には必須検討事項。**Codex adversarial review が investigation 対象自身を analyze する recursive case では、self-finding を最優先 signal として扱う**。

## Consequences

### Positive

- Step 0a で workaround 健在を実機確認、不要な option (d) (gpt-5.3 ロールフォワード) を排除できた。
- 4 mode 分類 logic (`classify_stage1`) で Stage 1 fail 原因を機械的に切り分け可能。silent failure (rc=0 + empty) も検出経路に含む。
- option (a1) / (a2) を分離したことで、broker cleanup helper の plugin internal API 依存リスクを bundle に隠さず別判断にできる。

### Risk / Trade-off

- **Probe 副作用**: bare CLI `codex-companion adversarial-review` は ADR 0012 §"Known side effect" 通り broker と job state file を残す。Step Z cleanup を Stage 1/2 ごとに実施しないと orphan が累積する。
- **Plugin update のロールバック手間**: Stage 1/2 probe の前段で `/plugin update` を発火する場合 (autoUpdate: false の一時剥がし)、Stage 1 fail 時に cache を `1.0.4` に戻す手段は marketplace `git reset --hard 807e03a` (1.0.4 commit) + Claude Code 再起動が必要。Step 0a smoke test では plugin update を発火しなかったため (現 cache 1.0.4 のまま probe SUCCESS)、Stage 1/2 probe でも plugin update は **必須ではない** — 現 cache のまま `--model` を抜くだけで Stage 1 probe は成立する。
- **option (b) は config.toml 変更を伴う bundle**: `~/.codex/config.toml` の `model` 変更は他の codex 利用箇所 (`/codex:rescue`, `/codex:review` 等) にも波及する。Issue #193 scope を超える副作用として明示。
- **Probe 結果の有効期限**: 現結果は 2026-05-09 時点の version 組み合わせで成立する。後日 plugin / CLI update された後は再 probe が必要。

### Lessons learned

Codex 自身が Step 0a smoke test の review で 2 件の [high] finding を指摘した:
1. probe コマンドに timeout/alarm wrapper の文書化が無く、`#183` hang 失敗を分類できない (probe 非再現性)
2. workaround path で probe して revert 判断の根拠にしている (false confidence)

両者は fair point で、本 ADR は両方を反映している (probe log への `perl alarm 600` 明記 + Step 0a と Stage 1 の概念分離)。次回類似の investigation では **「workaround path probe + revert path probe を最初から二重に計画する」** ことを brainstorming session の早期に意識すべき。

### 捨てた代替案

- **案 A (Issue #193 Plan の full execution)**: Stage 1/2 を必ず連続実走。Stage 1 で 70% 決まる構造を踏まえると過剰。
- **案 B (probe スキップ docs-only PR)**: upstream open のみで option (c) 直行。Goal "verify" を実走で満たさない、`gh api` 直叩きでも silent fix を完全に排除できない。
- **option (d) (gpt-5.3 ロールフォワード)**: #305 の regression window を懸念して一時提案したが、Step 0a SUCCESS で `--model gpt-5.4` pin の継続有効性が確認されたため不要化。

## References

- ADR 0012 §"Workaround — direct codex-companion invocation"
- ADR 0012 §"Known limitation — codex plugin model default broken on codex-cli 0.125.0 + plugin 1.0.4"
- ADR 0020 (Status revision pattern の前例)
- Issue #193 (本 investigation の起点)
- Issue #157 (closed; ADR 0012 workaround の origin)
- `openai/codex-plugin-cc#270` / `#183` / `#305` (upstream snapshot 2026-05-09; Stage 3 で `#183` symptom が wrapper-conditional に再現することを 2026-05-11 に確認)
- `docs/issues/193-probe-log.md` (probe 実走ログの作業帳; Stage 3 dogfood + Stage 3b disambiguating probe records 含む)
- PR #194 (option (a1) 実装 + Stage 3 dogfooding + Stage 3b disambiguating probe で REJECTED → superseded by this ADR's 2026-05-11 revision)
- Issue #189 (per-leg timeout reconcile origin) — superseded for tracking purposes by Issue #202 (本 ADR の Stage 3 hang を fail-loud 化するための直接的な follow-up)
- Issue #201 — "Investigate output-style triple-review × `/codex:adversarial-review --wait` hang root cause": Stage 3b で特定した 3-factor AND interaction の root cause 調査。option (a1) 再投資のための前提条件 #2
- Issue #202 — "Reconcile #189 per-leg timeout — wire 480s deadline to ADV `--wait` hang fail-loud": Codex `[high]` 勧告の bounded timeout 部分を実装、Stage 3 hang を fail-loud 化。option (a1) 再投資のための前提条件 #4 (path 独立な defense-in-depth)
