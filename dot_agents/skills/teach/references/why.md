# Why: establish rationale

Investigate forces that shaped the code without inventing author intent.

## Establish evidence

Anchor the question to files, symbols, a design choice, and relevant dates. When a repository is available, inspect scoped git blame, git log --follow -p, recent commits, linked PRs, and issues through available connectors or CLI. Comments and tests are clues, not conclusive evidence of historical motivation.

Discover available tools. Consider source control and PR discussion for implementation decisions; tickets for requirements; design documents for tradeoffs; team discussions for informal decisions; observability and incident records for operational constraints; error tracking for motivating failures; analytics for experiments and thresholds.

Start with history plus one or two promising sources. Keep track of the scope internally. Broaden for explicit historical investigations or conflicting evidence. For a broad sweep, examine every relevant available category and record empty findings or reasons for skipping. Do not run a full sweep for every question. Never send messages or modify systems during research. If sources are unavailable, use supplied material and state material limitations.

## Preserve confidence

- Observed behavior: supported by implementation or verified execution. Behavior alone does not establish motivation.
- Documented intent: an explicit rationale in a source. Identify when and by whom it was stated, and whether it applies to the current implementation.
- Supported inference: evidence suggests a rationale but does not state it. Use likely, suggests, or Japanese equivalents, with supporting evidence.
- Competing hypotheses: explain alternatives when the evidence does not settle the question. Look for evidence that would falsify the preferred account.
- Unknown: say the reason could not be established. Absence of records does not prove absence of reasons.

Trace beyond the latest commit when it merely moved existing code. Check dates, reversals, and contradictory records. Telemetry can support an operational constraint but rarely proves an author's intent by itself. Preserve uncertainty when teaching.

If the user is preparing a change, identify evidenced constraints to preserve and risks to verify without making changes. Provide a full source-coverage report only when requested or needed to assess the conclusion.
