---
name: teach
description: Explain code, changes, and subsystems by investigating how they work and why they were designed that way, then teach at the user's pace. Use for explicit teach requests, teach me this, help me understand this implementation, この実装を教えて, 仕組みと設計背景を知りたい, and understanding before review or modification. Do not trigger for every factual question or primarily implementation requests.
---

<!--
Adapted from pstack teach/how/why by Lauren Tan (@poteto).
Copyright (c) 2026 Lauren Tan. MIT License; see LICENSE.
Sources, pinned upstream revision, and adaptation notes: references/source.md.
Local adaptation: bundle how/why, remove Cursor/model/unslop dependencies,
use the user's language, and scope research and diagrams to the question.
-->

# Teach

Explain what the thing is, how it works, and why it has this shape. Help the person understand; do not modify their code while teaching.

This is a self-contained adaptation of pstack's teach/how/why workflow, not an official pstack installation. Read [source and attribution](references/source.md) for provenance. The investigation tracks are bundled references; no separately installed how, why, or unslop skill is required.

## Investigate

1. Infer the target, existing knowledge, and purpose from the conversation: onboarding, debugging, review, or preparation for a change. Skip concepts the person knows. State a reasonable interpretation and proceed when ambiguity is minor; ask only when the missing target blocks useful work. Use the user's language, Japanese for Japanese requests.
2. Orient yourself in the code, diff, or supplied material. Execute the [how track](references/how.md) for behavior and the [why track](references/why.md) for rationale. Use both for a subsystem. A narrow behavior-only question may need only how. Scope why to history plus one or two promising sources initially, widening when rationale is central or sources conflict.
3. Use the tools actually available. Run independent searches concurrently when practical. If permitted and useful, delegate bounded read-only investigations, then verify and synthesize their evidence. Otherwise perform the tracks directly. Require no specific platform or model. Never imply access to unavailable repositories, documents, or telemetry.
4. Combine the results into one account. Preserve observed facts, documented intent, supported inference, competing explanations, and unknowns. Do not remove uncertainty to make the prose smoother. Check material claims against original evidence.

## Teach

- Start with a plain definition and connect it to the concrete case. Give the smallest complete answer in one or two sentences, then let the person respond. For a one-shot task or an explicit request for detail, provide the requested depth without artificial pauses.
- Explain the problem being solved and walk through one concrete operation. Follow runtime events when helpful. Avoid a tour of function names and constants.
- Deepen through follow-up questions. Keep it conversational. Do not quiz, ask the user to repeat the answer, or announce theatrical pauses. Do not assume an explanation proves understanding.
- Use concise diagrams, diffs, or examples when they clarify the mechanism. Introduce complex flows a small part at a time across the conversation. Do not force diagrams for simple points or repeat nearly identical diagrams in a short response.
- Use edge cases or counterexamples when they test the explanation. Separate historical motivation from your assessment of whether the current design is appropriate. Do not assume every detail was intentional or optimal.
- Cite original code, PRs, or documents near material claims. Mention unavailable sources when they materially limit the conclusion. Keep research notes internal unless requested.
- Write natural, direct prose. Avoid stock framing labels, excessive headings, and walls of text. Return the explanation itself, not an activity report. Follow the person's lead about deepening or moving on.
