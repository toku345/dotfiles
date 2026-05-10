# ADR 0021: triple-review ADV leg revert investigation (Issue #193)

## Status

Accepted (2026-05-09, revised 2026-05-10).

**Revision (2026-05-10, post Stage 1/2 probes)**: Stage 1 (model unpin) と Stage 2 (slash dispatch) の両 probe が SUCCESS で完了 — 両 workaround の動機 (upstream `openai/codex-plugin-cc#270` + `#183`) はいずれも本日のローカル環境 (codex-cli `0.130.0` + plugin `1.0.4` + Claude Code `2.1.137`) で再現せず。**option (a1) 採用**: `dot_local/bin/executable_triple-review:917-927` を `claude_p_neutral "/codex:adversarial-review --wait --base \"$base\" --scope branch"` に置換し、`--model gpt-5.4` pin と direct codex-companion bypass を同時撤去。`private_dot_claude/settings.json:188` の `autoUpdate: false` は ADR 0012 §"Workaround" の broker cleanup helper plugin-internal-API 依存性 (Issue #163) を別途解消するまで維持 — option (a2) は本 Issue では eligibility gate を満たさず deferred。Stage 1 SUCCESS は upstream `#270` still open 状態と矛盾するが `gh api` 再確認で state 不変を確認済 (last activity 2026-04-26)。Stage 2 SUCCESS も `#183` open + PR `#184` unmerged 状況と矛盾するが、本ローカル環境では hang 再現せず — workaround は導入時環境で正しかったが環境が変わった。両 probe transcripts は `docs/issues/193-probe-log.md` Stage 1/2 sections 参照。

This ADR records the investigation framework, the Step 0a smoke-test result, and the decision tree used to choose between revert options. The final option (a1 / a2 / b / c) is chosen after Stage 1/2 probes complete; that choice will be appended via a `**Revision (...)**` paragraph in the Status section, following the ADR 0020 pattern.

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

`#305` は本投資的に新規発見。「CLI 0.128.0+ で `--model gpt-5.4` も `unknown_parameter` で 400 を返すよう regression が広がった」と報告 → ローカル `codex-cli 0.130.0` (#305 reporter 環境よりさらに新しい) で `--model gpt-5.4` pin 自体が壊れている可能性が浮上し、option (d) (`gpt-5.3` ロールフォワード) の緊急性を検討する必要が生じた。

### Step 0a (smoke test result, 2026-05-09 17:55:13 — 17:56:39 JST)

#305 由来の懸念を解消するため、現 workaround 構成 (`--model gpt-5.4` pin) で bare CLI smoke test を実走:

- **Command**: `perl -e 'alarm 600; exec @ARGV' node "$CODEX_COMPANION" adversarial-review --base main --scope branch --model gpt-5.4 > $LOGDIR/adv.md 2> $LOGDIR/adv.err`
- **Environment**: codex-cli `0.130.0`, plugin `1.0.4`, Claude Code `2.1.137`, `~/.codex/config.toml` model `gpt-5.5`
- **Outcome**: rc=0, elapsed 86s, adv.md 2,397 bytes, adv.err 977 bytes
- **Classification**: SUCCESS (real review with `Verdict: needs-attention` + 2 [high] findings + recommendations; adv.err ends with `[codex] Turn completed.`)
- **#305 signature**: `Invalid value: 'custom'` / `unknown_parameter` 検出なし

→ ローカル CLI 0.130.0 では `--model gpt-5.4` pin は依然機能している。**option (d) (gpt-5.3 ロールフォワード) の緊急性は消失。Issue #193 元 Plan (Stage 1/2 → option a/b/c) で進む。**

なお Codex 自身が smoke test 中に probe log の脆弱性 2 件を [high] で指摘した (timeout/alarm wrapper 文書化漏れ + workaround path success が revert 判断の root false confidence)。両指摘は本 ADR の設計に組み込み済 (probe log の `perl alarm` 明示 / Step 0a と Stage 1 の概念分離)。

### Step 0a の解釈 (R14)

Step 0a SUCCESS は「現 workaround が 2026-05-09 時点で機能している」事実を示すのみ。これは workaround 維持の根拠でも revert の根拠でもなく、**Stage 1/2 probe で revert path の動作可否を独立に検証する** 必要がある。

## Decision

### 判断ツリー

```
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

- [x] Step 0a 結果記録 (smoke test SUCCESS rc=0 86s)
- [ ] Step 1 (Stage 1 probe) 実走 + 結果分類 ({SUCCESS|HANG|400|SANDBOX|SILENT|OTHER})
- [ ] Step Z (probe cleanup) 実走 (broker / ghost job state 除去)
- [ ] Step 2 (Stage 2 probe) 実走 (Stage 1 SUCCESS 時のみ) + 結果分類
- [ ] option (a1/a2/b/c) のいずれかを採用 + 採用理由を Status revision に記録
- [ ] (option (b) 採用時) 変更先 model の smoke test SUCCESS 確認 (gpt-5.4 なら Step 0a で代用可)
- [ ] bats T3-7 更新 (採用 option に応じて)
- [ ] bats-docker-parity-runner verified green
- [ ] ADR 0012 §"Workaround" / §"Known limitation" に最終 Status revision 追記

※ 必須ゲート (動作検証・既存機能・差分確認・シークレット) は常に適用。

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
- `openai/codex-plugin-cc#270` / `#183` / `#305` (upstream snapshot 2026-05-09)
- `docs/issues/193-probe-log.md` (probe 実走ログの作業帳)
