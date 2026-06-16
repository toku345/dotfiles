# pr-review Review Criteria

This file is the skill-bundled detailed gate policy for `$pr-review`. Global `AGENTS.md` / `CLAUDE.md` files should keep only the short cross-repository policy; this file is the source of truth for this skill's severity normalization, output budgeting, and re-review behavior.

## Review Modes

- **Quick review**: use built-in or local review for typo-level, mechanical, or low-risk changes. Do not run this skill only to maximize findings.
- **Gate review**: use `$pr-review` for high-risk changes, broad diffs, pre-merge confidence, or changes touching authorization, security, data integrity, deployment, review/runtime automation, or other operational control planes. Optimize for merge decisions, not finding count.
- **Audit review**: use additional security or release-specific review when the change crosses trust boundaries, production rollout behavior, or irreversible data paths. Keep the final fix queue limited to blockers and the most useful non-blockers.

## Finding Acceptance

A finding may enter the final fix queue only when it is grounded in the committed branch diff and explains a concrete risk. Prefer file:line, observed failure mode, user or operational impact, and the smallest reasonable fix.

Do not put nits, style preferences, speculative rewrites, or weakly grounded concerns into the fix queue. If evidence is incomplete but the risk may be severe, keep the finding with the missing verification stated explicitly; do not silently drop it.

Every specialist finding must expose the decision fields the aggregator needs: `blocking: yes/no`, `impact_scope`, `verified_assumptions`, and `unverified_assumptions`. Use `blocking: yes` only when the committed diff creates a clear merge-blocking risk; otherwise use `blocking: no` and let the aggregator classify the issue as Important or Suggestion.

## Severity

- **Critical**: clear merge blocker. Use only when this branch, if merged as-is, clearly breaks user-visible behavior, safety/security, data integrity, deploy/apply behavior, or an authoritative gate, including a proven silent false-green in that gate. A Critical finding must identify the affected `impact_scope`, list verified assumptions, and have no unverified assumption required for the blocker claim.
- **Important**: likely worth fixing before merge but not yet a proven blocker. Important findings are capped at 5 in the final aggregation; prefer the highest-impact items.
- **Suggestion**: optional improvement that materially helps the user. Suggestions are capped at 3 in the final aggregation.
- **Nit**: style-only, preference-only, naming-only, or speculative cleanup. Nits do not enter the fix queue.

Machine-local or ignored state, local-only performance regressions, advisory observability gaps, and false-green concerns limited to a developer's local workflow are not Critical by default. Classify them as Important only when they are concrete enough to fix before merge; otherwise classify them as Suggestions. Do not promote a single specialist's Critical label unchanged: re-check the committed diff, `impact_scope`, and verified assumptions against the Critical definition.

Post-verification, a Critical candidate whose verifier verdict is `needs-verification` with a non-empty `missingVerification` is Important, not Critical. Keep the missing verification visible in the fix queue, but do not call the item a proven merge blocker until the missing proof exists. Other verdicts carrying `missingVerification`, or `needs-verification` without it, are invalid verifier outputs and must fail closed.

## Re-review

Re-review verifies prior Critical/Important findings. First confirm whether each prior high-priority finding was fixed, remains, or was intentionally rejected. Raise new findings only when they are clear merge blockers; do not extend the loop with new nits, style feedback, or optional refactors.

Stop conditions:
- If the result is `Critical 0 / Important 0`, stop the gate loop.
- If only Suggestions remain, do not re-run the gate just to chase them.
- On the second and later review pass, focus on prior Critical/Important resolution; new findings require clear merge-blocker evidence.
- On the third and later pass, if Critical/Important findings keep appearing or changing without a stable blocker, call out possible review churn and return the decision to a human maintainer.
