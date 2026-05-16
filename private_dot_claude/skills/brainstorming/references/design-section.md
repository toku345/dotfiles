# Presenting the design

Read this file before Checklist step 4 (present design in sections).

## Section partition (menu, not mandatory sequence)

The standard menu of design sections is **architecture / components / data flow / error handling / testing**. Treat it as a menu, not a fixed sequence. Pick the sections the work actually needs; skip ones that are trivial; add one (e.g., security, performance, migration) when the work demands it. A todo-list utility might only need "components" and "testing"; a payments integration needs all five plus security.

## ASCII art convention

Use plain ASCII characters (`+`, `-`, `|`, `>`, `v`) for box-and-arrow diagrams so they render correctly in terminals. Use diagrams for architecture, state transitions, sequence flows, or data flows whenever they aid understanding. Don't use diagrams as decoration — if a diagram doesn't help the reader, words are clearer.

## Scale calibration

Scale each section to its complexity:

- A few sentences for straightforward sections.
- Up to ~200-300 words when the section has real nuance to explain.
- If a section is growing past 300 words, it likely contains a hidden sub-design — split it.

## Decision-shaped approval cadence

After each section, ask whether it looks right so far. Frame the check as a decision the user can act on ("Does this match your priorities? Anything to adjust before I move on?"), not as a yes/no rubber stamp. One-question-per-message still applies here.

## Design for isolation

Break the system into smaller units that each have one clear purpose, communicate through well-defined interfaces, and can be understood and tested independently. For each unit, you should be able to answer: what does it do, how do you use it, and what does it depend on?

Two diagnostics:

- Can someone understand what a unit does without reading its internals? If not, the public surface is wrong.
- Can you change the internals without breaking consumers? If not, the boundary is leaking.

Smaller, well-bounded units are also easier to work with — code is more reliable when files are focused. When a file grows large, that's often a signal it's doing too much.

## Working in existing codebases

- Explore the current structure before proposing changes. Follow existing patterns.
- Where existing code has problems that affect the work (e.g., a file that's grown too large, unclear boundaries, tangled responsibilities), include targeted improvements as part of the design — the way a good developer improves code they're working in.
- Don't propose unrelated refactoring. Stay focused on what serves the current goal.

## Pivot handling

Mid-design, the user may correct you. Distinguish two cases:

- **Local correction** ("not that detail, do this instead"): adjust the current section and continue.
- **Material goal change** ("actually I want X, not Y"): stop the section walk, restart from Checklist step 1 (re-explore context) or step 2 (re-ask the foundational question). Don't try to patch around a moved goalpost.

Be willing to throw away work in flight. Sunk-cost reasoning on a not-yet-implemented design is cheap to avoid.

## Process Flow at a glance

```
+---------------------------+
| Explore project context   |
+---------------------------+
            |
            v
   +------------------+
   | Multiple         |
   | subsystems?      |
   +------------------+
    |yes          |no
    v             |
+--------------+  |
| Decompose    |  |
| sub-projects |  |
+--------------+  |
    |             |
    v             v
+---------------------------+
| Ask clarifying questions  |
+---------------------------+
            |
            v
+---------------------------+
| Propose 2-3 approaches    |
+---------------------------+
            |
            v
+---------------------------+
| Present design sections   |<-----+
+---------------------------+      |
            |                      |
            v                      |
   +------------------+            |
   | User approves?   |--- no ----+
   +------------------+
            |yes
            v
+---------------------------+
| Write ADR(s)              |<-----+
+---------------------------+      |
            |                      |
            v                      |
   +------------------+            |
   | User confirms    |            |
   | ADR?             |            |
   +------------------+            |
    |yes          |no -------------+
    v
+---------------------------+
| Commit (opt-in,           |
| branch safety)            |
+---------------------------+
            |
            v
+---------------------------+
| Guide user to plan mode   |
+---------------------------+
```
