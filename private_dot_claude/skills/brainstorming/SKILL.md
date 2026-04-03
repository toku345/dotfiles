---
name: brainstorming
description: ソクラテス式対話で要件と設計を詰めてから実装方針を固めるブレインストーミングスキル。「ブレスト」「設計を考えたい」「どう実装すべきか」「アーキテクチャを相談したい」「設計相談」「実装の前に整理したい」「方針を決めたい」などのリクエストで発動する。
---

<!--
  Based on: obra/superpowers — Brainstorming Skill
  Original: https://github.com/obra/superpowers/blob/eafe962b18f6c5dc70fb7c8cc7e83e61f4cdde06/skills/brainstorming/SKILL.md

  MIT License
  Copyright (c) 2025 Jesse Vincent

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  SOFTWARE.

  Customizations from original:
  - Removed Visual Companion (browser-based tool) — using ASCII art diagrams instead
  - Removed writing-plans skill invocation — using Claude Code plan mode instead
  - Did not adopt git worktree automation from the broader superpowers ecosystem
  - Removed references to other superpowers skills (writing-plans, frontend-design, mcp-builder, elements-of-style)
  - Added explicit scope pre-assessment step
  - Replaced design spec output with ADR(s) (project convention, default: docs/adr/)
  - Converted Process Flow from graphviz to ASCII art (terminal-readable)
  - Relaxed one-question-at-a-time rule — allow batching 2-3 related questions
  - Prefer hypothesis-driven questioning over interrogation style
  - Added branch safety check before committing
  - Simplified transition to plan mode
  - Description in Japanese for trigger phrase matching
-->

# Brainstorming Ideas Into Designs

Help turn ideas into fully formed designs and specs through natural collaborative dialogue.

Start by understanding the current project context, then ask focused questions to refine the idea. Once you understand what you're building, present the design, get user approval, and record key decisions as ADRs.

<HARD-GATE>
Do NOT invoke any implementation skill, write any code, scaffold any project, or take any implementation action until you have presented a design and the user has approved it. This applies to EVERY project regardless of perceived simplicity.
</HARD-GATE>

## Anti-Pattern: "This Is Too Simple To Need A Design"

Every project goes through this process. A todo list, a single-function utility, a config change — all of them. "Simple" projects are where unexamined assumptions cause the most wasted work. The design can be short (a few sentences for truly simple projects), but you MUST present it and get approval.

## Checklist

You MUST create a task for each of these items and complete them in order:

1. **Explore project context and assess scope** — check files, docs, recent commits. Evaluate whether the request contains multiple independent subsystems that should be decomposed first.
2. **Ask clarifying questions** — batch 2-3 related questions per message; prefer hypothesis-driven ("here's my understanding, correct me") over open-ended interrogation
3. **Propose 2-3 approaches** — with trade-offs and your recommendation
4. **Present design** — in sections scaled to their complexity, get user approval after each section. Use ASCII art diagrams where they aid understanding.
5. **Write ADR(s)** — record key design decisions to the project's ADR directory (default: `docs/adr/NNNN-<slug>.md`; adapt to the project's conventions). Auto-detect next number.
6. **Commit ADR(s)** — after user confirms the ADR(s), verify branch safety and commit to git (opt-in: skip if the user prefers not to commit)

## Process Flow

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
| Propose 2-3 approaches   |
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
| Write ADR(s)              |
+---------------------------+
            |
            v
   +------------------+
   | User confirms    |
   | ADR?             |
   +------------------+
            |yes
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

## The Process

**Understanding the idea:**

- Check out the current project state first (files, docs, recent commits)
- Before asking detailed questions, assess scope: if the request describes multiple independent subsystems (e.g., "build a platform with chat, file storage, billing, and analytics"), flag this immediately. Don't spend questions refining details of a project that needs to be decomposed first.
- If the project is too large for a single spec, help the user decompose into sub-projects: what are the independent pieces, how do they relate, what order should they be built? Then brainstorm the first sub-project through the normal design flow. Each sub-project gets its own spec → plan → implementation cycle.
- For appropriately-scoped projects, ask focused questions to refine the idea
- Prefer hypothesis-driven questions ("Based on X, I'm assuming Y — is that right?") over open-ended interrogation ("What do you want for Y?"). This builds on what you've already learned and feels collaborative rather than like a questionnaire.
- Batch 2-3 closely related questions in a single message when they share context (e.g., "For the auth layer: do you need OAuth, and if so, which providers? Also, should sessions be stateless (JWT) or server-side?"). Unrelated topics should still be separate messages.
- Prefer multiple-choice questions when possible, but open-ended is fine too
- Focus on understanding: purpose, constraints, success criteria

**Exploring approaches:**

- Propose 2-3 different approaches with trade-offs
- Present options conversationally with your recommendation and reasoning
- Lead with your recommended option and explain why

**Presenting the design:**

- Once you believe you understand what you're building, present the design
- Scale each section to its complexity: a few sentences if straightforward, up to 200-300 words if nuanced
- Ask after each section whether it looks right so far
- Cover: architecture, components, data flow, error handling, testing
- Be ready to go back and clarify if something doesn't make sense
- **Use ASCII art diagrams** to illustrate architecture, state transitions, sequence flows, or data flows wherever they aid understanding. Use plain ASCII characters (`+`, `-`, `|`, `>`, `v`) for box-and-arrow diagrams so they render correctly in terminals.

**Design for isolation and clarity:**

- Break the system into smaller units that each have one clear purpose, communicate through well-defined interfaces, and can be understood and tested independently
- For each unit, you should be able to answer: what does it do, how do you use it, and what does it depend on?
- Can someone understand what a unit does without reading its internals? Can you change the internals without breaking consumers? If not, the boundaries need work.
- Smaller, well-bounded units are also easier for you to work with — you reason better about code you can hold in context at once, and your edits are more reliable when files are focused. When a file grows large, that's often a signal that it's doing too much.

**Working in existing codebases:**

- Explore the current structure before proposing changes. Follow existing patterns.
- Where existing code has problems that affect the work (e.g., a file that's grown too large, unclear boundaries, tangled responsibilities), include targeted improvements as part of the design — the way a good developer improves code they're working in.
- Don't propose unrelated refactoring. Stay focused on what serves the current goal.

## After the Design

**Writing ADR(s):**

After the user approves the design, record key design decisions as ADR(s):

- Auto-detect the project's ADR directory and next number: list files in the ADR directory (default: `docs/adr/`; adapt to the project's conventions), find the highest `NNNN` prefix, and increment by 1 (zero-padded to 4 digits). If no ADR directory exists, create `docs/adr/` starting at `0001`.
- Use this ADR format:
  ```
  # ADR NNNN: <Title>

  ## Status

  Accepted

  ## Context

  <Why this decision was needed — the forces at play>

  ## Decision

  <What was decided and why>

  ## Consequences

  <What follows from this decision — positive, negative, and risks>
  ```
- One ADR per distinct design decision. If the brainstorming session produced a single cohesive decision, write one ADR. If it produced multiple independent decisions, write separate ADRs.
- The ADR captures the *decision and its rationale*, not the full design. The design conversation itself is the primary record of requirements and exploration.

After writing, present the ADR(s) to the user and ask for confirmation before proceeding.

**Commit after approval (opt-in):**

If the user prefers not to commit, skip this step. When committing:

1. **Branch safety check**: Verify the current branch is suitable for commits.
   - Reject detached HEAD state (`git branch --show-current` returns empty).
   - Detect the repository's default branch (`git rev-parse --abbrev-ref origin/HEAD 2>/dev/null`). If detection fails, check against common defaults: `main`, `master`, `trunk`, `develop`.
   - If on the default branch, warn the user and suggest creating a feature branch before committing. Do not commit to the default branch without explicit user confirmation.
2. Commit the ADR file(s) to git.

**Transition to plan mode:**

After the design is approved, let the user know they can proceed:

> "Requirements are clear and ADR(s) written. Switch to plan mode when you're ready to create an implementation plan."

Do NOT write code, scaffold projects, or take any implementation action. The brainstorming skill's responsibility ends when the design is approved and the user is guided to plan mode.

## Key Principles

- **Focused, hypothesis-driven questions** — Batch 2-3 related questions; lead with your understanding for the user to confirm or correct
- **Multiple choice preferred** — Easier to answer than open-ended when possible
- **YAGNI ruthlessly** — Remove unnecessary features from all designs
- **Explore alternatives** — Always propose 2-3 approaches before settling
- **Incremental validation** — Present design, get approval before moving on
- **Be flexible** — Go back and clarify when something doesn't make sense
- **Visualize with ASCII art** — Use diagrams for architecture, state machines, sequences, and data flows
