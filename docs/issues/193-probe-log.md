# Issue #193 probe log

Investigation log for [Issue #193](https://github.com/toku345/dotfiles/issues/193) — verify whether the `triple-review` ADV leg workarounds (direct `codex-companion` invocation + `--model gpt-5.4` pin) can be reverted.

This file is the in-tree work log so the adversarial-review leg has a non-trivial diff to operate on during the smoke test.

## Step 0: upstream state snapshot (2026-05-09)

| Issue | State | Last activity | Cross-refs |
|---|---|---|---|
| `openai/codex-plugin-cc#270` (gpt-5.5 default broken) | **open** | 2026-04-26 | `toku345/dotfiles#157` (closed), `openai/codex-plugin-cc#305` (closed 2026-05-08) |
| `openai/codex-plugin-cc#183` (captureTurn await forever) | **open** | 2026-04-08 | PR `#184` (open, not merged) |
| `openai/codex-plugin-cc#305` (gpt-5.4 + gpt-5.5 reject `tools: 'custom'`) | **closed** 2026-05-08 (`"filing in our internal tracker instead"`) | 2026-05-08 | — |

### Implication

`#305` reports that on `codex-cli >= 0.128.0`, `--model gpt-5.4` itself fails with `unknown_parameter` (regression window widened from `gpt-5.5`-only to include `gpt-5.4`). Local `codex-cli` is `0.130.0`, which is inside that regression window — but a 2026-05-06 `triple-review` work-dir log (`$TMPDIR/triple-review-{jIQrFt,yKqDox,J81jI9}`) shows `Turn completed.` with real review content, suggesting `gpt-5.4` was still functional 3 days ago. CLI version on 2026-05-06 is unrecorded; it may have been `< 0.128.0`.

The smoke test below resolves this ambiguity.

## Step 0a: smoke test (in-flight)

Bare-CLI invocation against this probe branch:

```bash
node "$CODEX_COMPANION" adversarial-review --base main --scope branch --model gpt-5.4
```

Decision matrix:

| Outcome | adv.md | adv.err | rc | Path |
|---|---|---|---|---|
| Real review | `Verdict: …` + findings | ends with `Turn completed.` | 0 | Stage 1 (model unpin) probe meaningful — proceed |
| `unknown_parameter` 400 | empty/placeholder | contains `Invalid value: 'custom'` or `unknown_parameter` | non-zero | option (d) rolling forward to `--model gpt-5.3` required |
| Hang then kill | partial / empty | partial | killed by perl alarm | upstream `#183` regression — option (d) likely still required |
| Placeholder | "Codex のレビューがまだ進行中です" | `Turn completed` but empty payload | 0 | upstream `#183` silent variant — option (d) still required |

Result will be appended below once the probe completes.
