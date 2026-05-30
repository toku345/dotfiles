# pr-review Review Criteria

This file is the skill-bundled detailed gate policy for `$pr-review`. Global `AGENTS.md` / `CLAUDE.md` files should keep only the short cross-repository policy; this file is the source of truth for this skill's severity normalization, output budgeting, and re-review behavior.

## Review Modes

- **Quick review**: use built-in or local review for typo-level, mechanical, or low-risk changes. Do not run this skill only to maximize findings.
- **Gate review**: use `$pr-review` for high-risk changes, broad diffs, pre-merge confidence, or changes touching authorization, security, data integrity, deployment, review/runtime automation, or other operational control planes. Optimize for merge decisions, not finding count.
- **Audit review**: use additional security or release-specific review when the change crosses trust boundaries, production rollout behavior, or irreversible data paths. Keep the final fix queue limited to blockers and the most useful non-blockers.

## Finding Acceptance

A finding may enter the final fix queue only when it is grounded in the committed branch diff and explains a concrete risk. Prefer file:line, observed failure mode, user or operational impact, and the smallest reasonable fix.

Do not put nits, style preferences, speculative rewrites, or weakly grounded concerns into the fix queue. If evidence is incomplete but the risk may be severe, keep the finding with the missing verification stated explicitly; do not silently drop it.

## Severity

- **Critical**: clear merge blocker. Use for concrete security exposure, data loss, crash, authorization or permission breakage, user-visible correctness regression, operational outage risk, deploy/apply false-green, silent false-green, or violation of explicit target-repository guidance.
- **Important**: likely worth fixing before merge but not yet a proven blocker. Important findings are capped at 5 in the final aggregation; prefer the highest-impact items.
- **Suggestion**: optional improvement that materially helps the user. Suggestions are capped at 3 in the final aggregation.
- **Nit**: style-only, preference-only, naming-only, or speculative cleanup. Nits do not enter the fix queue.

## Re-review

Re-review verifies prior Critical/Important findings. First confirm whether each prior high-priority finding was fixed, remains, or was intentionally rejected. Raise new findings only when they are clear merge blockers; do not extend the loop with new nits, style feedback, or optional refactors.
