#!/usr/bin/env python3
"""Verify Claude/Codex update policy and permission gate settings.

This keeps ADR 0026's AI-tool update controls and the load-bearing
``permissions`` entries recorded in ADR 0036 / ADR 0014 from silently drifting
while the durable runbook still claims those controls are enforced.
"""

from __future__ import annotations

import json
import pathlib
import re
import sys


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_SETTINGS = REPO_ROOT / "private_dot_claude" / "settings.json"

# Content-scoped ask rules are evaluated before the auto-mode classifier and
# always prompt, so these are the effective gates behind the CLAUDE.md
# pre-flight list. Claude Code v2.1.211 dropped the protected-branch default,
# which leaves "Bash(git push:*)" as the only thing stopping a direct push to
# main (ADR 0036); "Bash(chezmoi apply:*)" is the two-layer gate ADR 0014
# depends on. "Bash(git clean:*)" closes the rm / reset / clean line of the
# pre-flight list, the last of those three that had steering but no ask rule
# (Issue #343). Required subset, not an exact list: adding entries is fine.
# Atlassian entries pin the intended policy; these source checks do not prove
# connector name resolution or a live approval UI. See docs/agent-permissions.md.
REQUIRED_ASK_ENTRIES = (
    "mcp__claude_ai_Atlassian_Rovo__create*",
    "mcp__claude_ai_Atlassian_Rovo__transition*",
    "mcp__claude_ai_Atlassian_Rovo__addCommentToJiraIssue",
    "Bash(git push:*)",
    "Bash(git commit:*)",
    "Bash(git reset:*)",
    "Bash(git clean:*)",
    "Bash(rm:*)",
    "Bash(chezmoi apply:*)",
    "Bash(gh api:*)",
    "Bash(gh pr create:*)",
    "Bash(gh pr edit:*)",
    "Bash(gh pr merge:*)",
    "Bash(gh pr close:*)",
    "Bash(gh pr reopen:*)",
    "Bash(gh pr comment:*)",
    "Bash(gh pr review:*)",
    "Bash(gh pr ready:*)",
    "Bash(gh pr lock:*)",
    "Bash(gh pr unlock:*)",
    "Bash(gh issue create:*)",
    "Bash(gh issue edit:*)",
    "Bash(gh issue close:*)",
    "Bash(gh issue reopen:*)",
    "Bash(gh issue comment:*)",
    "Bash(gh issue delete:*)",
    "Bash(gh issue lock:*)",
    "Bash(gh issue unlock:*)",
)

# Read deny rules block Claude's built-in file tools and the Bash file commands
# Claude Code recognizes, independently of the sandbox; when the sandbox is on
# they are also merged into its filesystem boundary. ADR 0001's empirical
# baseline snapshot found "~/.config/gcloud/**" and "~/.terraform.d/**" absent
# from Anthropic's built-in deny, so for those two this list is the only layer.
# "~/.aws/**" is a glob on purpose: enumerating config + credentials left
# ~/.aws/cli/cache/** and ~/.aws/sso/cache/** readable (Issue #303).
REQUIRED_DENY_ENTRIES = (
    "Read(~/.aws/**)",
    "Read(~/.config/gcloud/**)",
    "Read(~/.config/gh/hosts.yml)",
    "Read(~/.docker/config.json)",
    "Read(~/.kube/config)",
    "Read(~/.netrc)",
    "Read(~/.npmrc)",
    "Read(~/.ssh/**)",
    "Read(~/.terraform.d/**)",
)

# ADR 0036 removed this narrow allow rule so the full command, including its
# --sandbox options, reaches the auto-mode classifier instead of resolving
# ahead of it. Re-adding it needs a deliberate decision, not an "always allow".
# Generic run permissions also skip classifier review on unsandboxed retries.
# Keep both equivalent trailing-wildcard spellings out of the global allow list.
# The commit-commands plugin is disabled; retain no stale Skill permission.
# An allow match skips the classifier (and, by inference, managed hard_deny)
# and runs unprompted on unsandboxed retry; see ADR 0002 "Follow-up 2026-11-18".
FORBIDDEN_ALLOW_ENTRIES = (
    "Skill(commit-commands:commit-push-pr)",
    "Bash(codex exec:*)",
    "Bash(npm run:*)",
    "Bash(npm run *)",
    "Bash(yarn run:*)",
    "Bash(yarn run *)",
    "Bash(cargo run:*)",
    "Bash(cargo run *)",
    "Bash(npm test:*)",
    "Bash(npm test *)",
    "Bash(yarn test:*)",
    "Bash(yarn test *)",
    "Bash(cargo build:*)",
    "Bash(cargo build *)",
    "Bash(cargo test:*)",
    "Bash(cargo test *)",
    "Bash(cargo check:*)",
    "Bash(cargo check *)",
    "Bash(git fetch:*)",
    "Bash(git fetch *)",
    "Bash(chezmoi diff:*)",
    "Bash(chezmoi diff *)",
    "Bash(chezmoi status:*)",
    "Bash(chezmoi status *)",
    "Bash(chezmoi cat:*)",
    "Bash(chezmoi cat *)",
    "Bash(jq:*)",
    "Bash(jq *)",
    "Bash(tree:*)",
    "Bash(tree *)",
    "Bash(git diff:*)",
    "Bash(git diff *)",
    "Bash(git log:*)",
    "Bash(git log *)",
    "Bash(git show:*)",
    "Bash(git show *)",
    "Bash(git status:*)",
    "Bash(git status *)",
    "Bash(git blame:*)",
    "Bash(git blame *)",
)

# Structural invariants for path rules in permissions.deny (Issue #303).
#
# Anchoring: Claude Code resolves "//path" from the filesystem root, "~/path"
# from $HOME, a single-slash "/path" relative to the settings *source*, and a
# bare or "./path" relative to the cwd. A user-global deny that is not "~/" or
# "//" anchored therefore guards a path under the cwd or under ~/.claude/, not
# the secret it names, and the sandbox merges cwd-relative deny rules into its
# filesystem boundary, which is what broke `chezmoi apply` and polluted
# `git status` with ghost char-special entries in Issue #212 (ADR 0001). Only
# Read and Edit rules are checked: those are the only path rules Claude Code
# consults. An entry that contains "(" but does not parse as Tool(spec) is
# rejected too, so a typo like "Read(~/.aws/**" cannot pass as a tool-level
# deny for a tool that does not exist.
#
# Dead rules: Claude Code checks file permissions against Read(path) and
# Edit(path) only. A path rule for Write, NotebookEdit, MultiEdit or Glob is
# accepted, never consulted, and only surfaces as a warning when an
# interactive session starts: protection that looks present but is not. A bare tool name
# without a path (e.g. "NotebookEdit") is a tool-level deny and is fine.
PATH_RULE_TOOLS = frozenset({"Read", "Edit"})
DEAD_PATH_RULE_TOOLS = frozenset({"Write", "NotebookEdit", "MultiEdit", "Glob"})
ANCHORED_PATH_PREFIXES = ("~/", "//")
_TOOL_RULE = re.compile(r"^(?P<tool>[A-Za-z_][A-Za-z0-9_]*)\((?P<spec>.*)\)$")


def deny_path_rule_failures(entry: object) -> list[str]:
    if not isinstance(entry, str):
        return [f"permissions.deny entry {entry!r} must be a string"]
    match = _TOOL_RULE.match(entry)
    if match is None:
        if "(" in entry:
            return [f'permissions.deny entry "{entry}" is not a well-formed Tool(spec) rule']
        return []
    tool = match.group("tool")
    spec = match.group("spec")
    if tool in DEAD_PATH_RULE_TOOLS:
        return [
            f'permissions.deny must not contain "{entry}": {tool}(path) rules are '
            "never consulted by Claude Code, use Edit(path) or Read(path)"
        ]
    if tool in PATH_RULE_TOOLS and not spec.startswith(ANCHORED_PATH_PREFIXES):
        return [
            f'permissions.deny entry "{entry}" must be anchored with "~/" or "//": '
            "a bare or single-slash path is resolved relative to the cwd or the "
            "settings source, not the filesystem root"
        ]
    return []


CODEX_PLUGIN_REPO = "openai/codex-plugin-cc"
CODEX_PLUGIN_DATA = "~/.claude/plugins/data/codex-openai-codex"
CODEX_PLUGIN_DATA_PARENT = "~/.claude/plugins/data"
# additionalMarketplaces is the v2.1.232 alias of extraKnownMarketplaces.
# strictKnownMarketplaces / allowedMarketplaces allow or block sources and do not register one.
MARKETPLACE_KEYS = ("extraKnownMarketplaces", "additionalMarketplaces")


def _names_codex_plugin_repo(value: object) -> bool:
    if not isinstance(value, str):
        return False
    text = value.strip().rstrip("/")
    if text.lower().endswith(".git"):
        text = text[:-4].rstrip("/")
    text = text.lower()
    needle = CODEX_PLUGIN_REPO
    return text == needle or text.endswith("/" + needle) or text.endswith(":" + needle)


def _marketplace_failures(key: str, marketplaces: object) -> list[str]:
    if not isinstance(marketplaces, dict):
        return [f"{key} must be an object"]
    failures: list[str] = []
    if "openai-codex" in marketplaces:
        failures.append(f"{key}.openai-codex must be absent")
    for name, marketplace in marketplaces.items():
        if not isinstance(marketplace, dict):
            failures.append(f"{key}.{name} must be an object")
            continue
        if "source" not in marketplace:
            continue
        source = marketplace.get("source")
        if not isinstance(source, dict):
            failures.append(f"{key}.{name}.source must be an object")
            continue
        for field in ("repo", "url"):
            if field not in source:
                continue
            field_value = source.get(field)
            if not isinstance(field_value, str):
                failures.append(f"{key}.{name}.source.{field} must be a string")
            elif _names_codex_plugin_repo(field_value):
                failures.append(f'{key} must not register "{CODEX_PLUGIN_REPO}"')
    return failures


def _normalize_allow_write(entry: str) -> str:
    text = entry.strip()
    for prefix in ("${HOME}/", "$HOME/", "~/"):
        if text.startswith(prefix):
            return "~/" + text[len(prefix) :]
    for root in ("/Users/", "/home/"):
        if text.startswith(root):
            rest = text[len(root) :]
            slash = rest.find("/")
            if slash > 0:
                return "~/" + rest[slash + 1 :]
    return text


def _strip_trailing_dot_slash(path: str) -> str:
    path = path.rstrip("/")
    if path.endswith("/."):
        path = path[: -len("/.")].rstrip("/")
    return path


def _glob_matches(pattern: str, candidate: str) -> bool:
    parts: list[str] = []
    index = 0
    while index < len(pattern):
        if pattern.startswith("**", index):
            parts.append(".*")
            index += 2
        elif pattern[index] == "*":
            parts.append("[^/]*")
            index += 1
        elif pattern[index] == "?":
            parts.append("[^/]")
            index += 1
        else:
            parts.append(re.escape(pattern[index]))
            index += 1
    return re.fullmatch("".join(parts), candidate) is not None


def _wildcard_covers_plugin(pattern: str) -> bool:
    if _glob_matches(pattern, CODEX_PLUGIN_DATA):
        return True
    if _glob_matches(pattern, CODEX_PLUGIN_DATA + "/x") or _glob_matches(
        pattern, CODEX_PLUGIN_DATA + "/x/y"
    ):
        return True
    ancestor = CODEX_PLUGIN_DATA
    while "/" in ancestor:
        ancestor = ancestor.rsplit("/", 1)[0]
        if ancestor in {"~", ""}:
            break
        if _glob_matches(pattern, ancestor):
            return True
    return False


def _grants_codex_plugin_data(entry: str) -> bool:
    path = _strip_trailing_dot_slash(_normalize_allow_write(entry))
    if path == CODEX_PLUGIN_DATA_PARENT:
        return False
    if "*" in path or "?" in path:
        return _wildcard_covers_plugin(path)
    return path == CODEX_PLUGIN_DATA or path.startswith(CODEX_PLUGIN_DATA + "/")


def _allow_write_failures(sandbox: object) -> list[str]:
    if not isinstance(sandbox, dict):
        return []
    filesystem = sandbox.get("filesystem")
    if not isinstance(filesystem, dict):
        return ["sandbox.filesystem must be an object"]
    allow_write = filesystem.get("allowWrite")
    if not isinstance(allow_write, list):
        return ["sandbox.filesystem.allowWrite must be an array"]
    failures: list[str] = []
    for entry in allow_write:
        if not isinstance(entry, str):
            failures.append("sandbox.filesystem.allowWrite entries must be strings")
            continue
        if _grants_codex_plugin_data(entry):
            failures.append(
                "sandbox.filesystem.allowWrite must not contain "
                f'"{CODEX_PLUGIN_DATA}"'
            )
    return failures


def validate_update_policy(data: object) -> list[str]:
    failures: list[str] = []

    if not isinstance(data, dict):
        return ["settings root must be an object"]

    env = data.get("env")
    if not isinstance(env, dict):
        failures.append("env must be an object")
    else:
        if env.get("DISABLE_AUTOUPDATER") != "1":
            failures.append('env.DISABLE_AUTOUPDATER must be "1"')
        if "FORCE_AUTOUPDATE_PLUGINS" in env:
            failures.append("env.FORCE_AUTOUPDATE_PLUGINS must be absent")

    if data.get("autoUpdatesChannel") != "stable":
        failures.append('autoUpdatesChannel must be "stable"')

    for key in MARKETPLACE_KEYS:
        if key in data:
            failures.extend(_marketplace_failures(key, data.get(key)))

    enabled_plugins = data.get("enabledPlugins")
    if not isinstance(enabled_plugins, dict):
        failures.append("enabledPlugins must be an object")
    elif any(
        isinstance(plugin_name, str) and plugin_name.startswith("codex@")
        for plugin_name in enabled_plugins
    ):
        failures.append("enabledPlugins must not contain Codex plugins")

    failures.extend(_allow_write_failures(data.get("sandbox")))

    return failures


def validate_permission_gates(data: object) -> list[str]:
    failures: list[str] = []

    if not isinstance(data, dict):
        return ["settings root must be an object"]

    permissions = data.get("permissions")
    if not isinstance(permissions, dict):
        return ["permissions must be an object"]

    ask = permissions.get("ask")
    if not isinstance(ask, list):
        failures.append("permissions.ask must be an array")
    else:
        for entry in REQUIRED_ASK_ENTRIES:
            if entry not in ask:
                failures.append(f'permissions.ask must contain "{entry}"')

    deny = permissions.get("deny")
    if not isinstance(deny, list):
        failures.append("permissions.deny must be an array")
    else:
        for entry in REQUIRED_DENY_ENTRIES:
            if entry not in deny:
                failures.append(f'permissions.deny must contain "{entry}"')
        for entry in deny:
            failures.extend(deny_path_rule_failures(entry))

    allow = permissions.get("allow")
    if not isinstance(allow, list):
        failures.append("permissions.allow must be an array")
    else:
        for entry in FORBIDDEN_ALLOW_ENTRIES:
            if entry in allow:
                failures.append(f'permissions.allow must not contain "{entry}"')

    # Keep bypassPermissions out of the baseline: it skips normal permission
    # checks even though some explicit prompts can survive in current versions.
    # Absent or any other mode passes. This does not cover --dangerously-skip-permissions
    # CLI flag, which only `disableBypassPermissionsMode` would block; that key
    # is deliberately not set here.
    if permissions.get("defaultMode") == "bypassPermissions":
        failures.append('permissions.defaultMode must not be "bypassPermissions"')

    # No permanent sandbox exclusions are approved in the integrated policy.
    # Bare names do not cover arguments (verified upstream on 2.1.310), while
    # wildcard exclusions remove filesystem/network containment. Pin [] rather
    # than suggest that adding a wildcard makes an exclusion safe (ADR 0002).
    sandbox = data.get("sandbox")
    if not isinstance(sandbox, dict):
        failures.append("sandbox must be an object")
    elif sandbox.get("excludedCommands") != []:
        failures.append("sandbox.excludedCommands must be an empty array")

    return failures


def parse_settings_path(argv: list[str]) -> pathlib.Path:
    if not argv:
        return DEFAULT_SETTINGS
    if len(argv) == 2 and argv[0] == "--settings":
        return pathlib.Path(argv[1])
    raise ValueError("usage: verify_claude_update_policy.py [--settings PATH]")


def main(argv: list[str] | None = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    try:
        settings = parse_settings_path(argv)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    try:
        data = json.loads(settings.read_text(encoding="utf-8"))
    except OSError as exc:
        print(f"ERROR: unable to read {settings}: {exc}", file=sys.stderr)
        return 2
    except json.JSONDecodeError as exc:
        print(f"ERROR: invalid JSON in {settings}: {exc}", file=sys.stderr)
        return 2

    failures = validate_update_policy(data) + validate_permission_gates(data)

    if failures:
        for failure in failures:
            print(f"ERROR: {failure}", file=sys.stderr)
        return 1

    print(
        "OK: Claude/Codex update policy and permission gate source settings "
        "match ADR 0026 / ADR 0036"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
