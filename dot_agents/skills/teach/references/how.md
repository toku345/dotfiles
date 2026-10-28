# How: establish behavior

Build a working mental model from evidence at the scope of the question.

1. Read relevant repository guidance. Identify the entry point, owning module, key data and state, dependencies, and observable output.
2. Trace one operation from input to output. Follow calls and transformations across relevant boundaries. Identify state changes, scheduling, errors, retries, and cleanup.
3. Inspect relevant callers and tests for contracts, invariants, and edge cases. Distinguish code inspected, intended behavior asserted in tests, and execution actually verified. Run a cheap read-only check only to resolve a specific uncertainty. Do not create tests or change code merely to explain it.
4. For a small target, investigate directly. For a large subsystem, use two to four distinct angles if authorized delegation is available, such as orchestration, persistence, and error handling. Give investigators the task and raw sources; require references and uncertainties. Verify that cross-module connections fit together.
5. Synthesize the mechanism, boundaries, invariants, and gotchas. Teach the few concepts needed to predict behavior rather than an exhaustive symbol inventory.
