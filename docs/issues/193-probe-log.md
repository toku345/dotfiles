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

## Stage 1 — model unpin probe (TBD)

Per ADR 0021 §"Decision". Result is appended below using the template.

```markdown
### Stage 1 probe (YYYY-MM-DD HH:MM:SS)

- Command: `<exact bash with perl alarm wrapper>`
- CLI versions: codex-cli X.Y.Z, plugin X.Y.Z, Claude Code X.Y.Z
- `~/.codex/config.toml` model: <value>
- Outcome: rc=N, elapsed=Ns, adv.md=N bytes
- Classification: {SUCCESS | HANG | 400 | SANDBOX | SILENT | OTHER}
- adv.err tail (last 20 lines): <excerpt>
- adv.md excerpt (first 30 lines or full if short): <excerpt>
```

(blank — to be filled by plan-mode execution)

## Stage 2 — slash-dispatch probe (TBD; only if Stage 1 SUCCESS)

Per ADR 0021 §"Decision". Result is appended below using the same template as Stage 1.

(blank — to be filled by plan-mode execution)

## Step Z — probe cleanup

Run after each Stage probe to clear orphan broker / ghost job state introduced by bare-CLI invocation (cf. ADR 0012 §"Known side effect").

```bash
# Broker cleanup helper (same one triple-review uses)
node "$HOME/.local/bin/triple-review-broker-cleanup" cleanup "$PWD" 2>&1 || true

# Ghost job state inspection (manual)
ls ~/.claude/plugins/data/codex-openai-codex/state/*/jobs/ 2>/dev/null | head
```

If the helper is unavailable or degrades silently, fall back to ADR 0012 §"Known side effect" — "Manual cleanup if the helper degrades silently".
