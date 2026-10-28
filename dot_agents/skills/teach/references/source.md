# Source and adaptation

<!--
Upstream author: Lauren Tan (@poteto), https://github.com/poteto
Copyright (c) 2026 Lauren Tan. License: MIT, full text in ../LICENSE.
Upstream repository: https://github.com/cursor/plugins
Upstream component: pstack teach/how/why skills.
Inspected revision: c742dd61706fbacc1b95f1a20b7b988cf096ce6c
Adapted: 2026-10-28 for toku345/dotfiles from the previously installed teach adaptation.
This is a derivative snapshot, not an official installation or automatically updated package.
-->

The upstream author and copyright holder is **Lauren Tan (@poteto)**.
The upstream material is licensed under MIT. Keep the copyright and permission notice in the bundled [LICENSE](../LICENSE) when copying or redistributing this adaptation; this comment is not a replacement for the license text.

Sources inspected at revision `c742dd61706fbacc1b95f1a20b7b988cf096ce6c`:

- [teach](https://github.com/cursor/plugins/blob/c742dd61706fbacc1b95f1a20b7b988cf096ce6c/pstack/skills/teach/SKILL.md)
- [how](https://github.com/cursor/plugins/blob/c742dd61706fbacc1b95f1a20b7b988cf096ce6c/pstack/skills/how/SKILL.md)
- [why](https://github.com/cursor/plugins/blob/c742dd61706fbacc1b95f1a20b7b988cf096ce6c/pstack/skills/why/SKILL.md)
- [MIT license](https://github.com/cursor/plugins/blob/c742dd61706fbacc1b95f1a20b7b988cf096ce6c/pstack/LICENSE)

## Local changes

- Bundle how and why as reference workflows within one teach skill instead of invoking separately installed skills.
- Replace Cursor-specific tool contracts and fixed model names with available capabilities; support direct investigation when delegation is unavailable.
- Use the user's language, including Japanese, and remove the separate unslop dependency.
- Keep research proportional to the question; do not require a full evidence sweep for every question.
- Preserve progressive explanation without mandatory repeated diagrams or generated images.
- Preserve the separation of behavior, documented rationale, inference, competing hypotheses, and unknowns.
- Store the canonical files under `dot_agents/skills/teach/`. Generate Claude Code's entry point, references, and license through thin chezmoi include wrappers.
- Disable implicit Codex invocation in `agents/openai.yaml` so teaching is opt-in. This does not claim equivalent Claude Code trigger enforcement.

The adaptation is maintained in this repository. It does not claim upstream endorsement or automatic updates. No pinned model, runtime script, network endpoint, or external skill is required by the package itself; evidence access depends on the tools available in the invoking session.
