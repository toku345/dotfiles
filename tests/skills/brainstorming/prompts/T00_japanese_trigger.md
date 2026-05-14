# T00 — Japanese trigger phrase

## Preconditions

- Fresh Claude Code session (no carry-over context).
- brainstorming skill installed at user-global scope; no project-level override.

## User turns

1. ブレストをお願い。新しい設定ファイル管理ツールを作りたい。

## Expected signals

- Skill auto-loads (visible in available-skills list or via skill-launch trace).
- Response acknowledges the brainstorming framing (does not jump to code or to plan mode).
- Response asks a clarifying question to begin Checklist step 1 or 2 (one decision per message).

## Anti-signals

- No skill load (the response is generic and does not surface design-first behavior).
- Immediately writes code, scaffolds files, or invokes an implementation skill.
- Eagerly reads all three reference files at session start (Read calls before any Checklist step fires).

## Leak guard

- Response does not paste verbatim text from references/*.md.
- Response does not list internal skill structure (e.g., "I will follow Checklist steps 1-7" verbatim) instead of doing the work.
- No reference file is read before its corresponding Checklist step fires.
