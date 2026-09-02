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
# depends on. Required subset, not an exact list: adding entries is fine.
REQUIRED_ASK_ENTRIES = (
    "Bash(git push:*)",
    "Bash(git commit:*)",
    "Bash(git reset:*)",
    "Bash(rm:*)",
    "Bash(chezmoi apply:*)",
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
FORBIDDEN_ALLOW_ENTRIES = ("Bash(codex exec:*)",)

# Structural invariants for path rules in permissions.deny (Issue #303).
#
# Anchoring: Claude Code resolves "//path" from the filesystem root, "~/path"
# from $HOME, a single-slash "/path" relative to the settings *source*, and a
# bare or "./path" relative to the cwd. A user-global deny that is not "~/" or
# "//" anchored therefore protects nothing outside the current directory, and
# the sandbox merges deny rules into its filesystem boundary relative to cwd,
# which is what broke `chezmoi apply` and polluted `git status` with ghost
# char-special entries in Issue #212 (ADR 0001). Only Read and Edit rules are
# checked: those are the only path rules Claude Code consults.
#
# Dead rules: Claude Code checks file permissions against Read(path) and
# Edit(path) only. A path rule for Write, NotebookEdit, MultiEdit or Glob is
# accepted, never consulted, and only surfaces as a startup warning nobody
# reads in CI: protection that looks present but is not. A bare tool name
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

    marketplaces = data.get("extraKnownMarketplaces")
    if not isinstance(marketplaces, dict):
        failures.append("extraKnownMarketplaces must be an object")
    else:
        marketplace = marketplaces.get("openai-codex")
        if not isinstance(marketplace, dict):
            failures.append("extraKnownMarketplaces.openai-codex must be present")
        else:
            source = marketplace.get("source")
            if not isinstance(source, dict):
                failures.append("extraKnownMarketplaces.openai-codex.source must be an object")
            else:
                if set(source) != {"source", "repo"}:
                    failures.append(
                        'extraKnownMarketplaces.openai-codex.source must contain only "source" and "repo"'
                    )
                if source.get("source") != "github":
                    failures.append('extraKnownMarketplaces.openai-codex.source.source must be "github"')
                if source.get("repo") != "openai/codex-plugin-cc":
                    failures.append(
                        'extraKnownMarketplaces.openai-codex.source.repo must be "openai/codex-plugin-cc"'
                    )
            if marketplace.get("autoUpdate") is not False:
                failures.append("extraKnownMarketplaces.openai-codex.autoUpdate must be false")

    enabled_plugins = data.get("enabledPlugins")
    if not isinstance(enabled_plugins, dict):
        failures.append("enabledPlugins must be an object")
    else:
        if enabled_plugins.get("codex@openai-codex") is not True:
            failures.append('enabledPlugins."codex@openai-codex" must be true')
        for plugin_name, enabled in enabled_plugins.items():
            if (
                isinstance(plugin_name, str)
                and plugin_name.startswith("codex@")
                and plugin_name != "codex@openai-codex"
                and enabled is True
            ):
                failures.append(
                    'enabledPlugins must not enable Codex plugins outside "codex@openai-codex"'
                )

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

    # A bypassPermissions default makes every pinned ask entry inert: the
    # entries are still present, but no prompt is ever raised. Absent or any
    # other mode passes. This does not cover the --dangerously-skip-permissions
    # CLI flag, which only `disableBypassPermissionsMode` would block; that key
    # is deliberately not set here.
    if permissions.get("defaultMode") == "bypassPermissions":
        failures.append('permissions.defaultMode must not be "bypassPermissions"')

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
