#!/usr/bin/env python3
"""Verify Claude/Codex update policy settings.

This keeps ADR 0026's AI-tool update controls from silently drifting while the
durable runbook still claims those controls are enforced.
"""

from __future__ import annotations

import json
import pathlib
import sys


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
DEFAULT_SETTINGS = REPO_ROOT / "private_dot_claude" / "settings.json"


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

    failures = validate_update_policy(data)

    if failures:
        for failure in failures:
            print(f"ERROR: {failure}", file=sys.stderr)
        return 1

    print("OK: Claude/Codex update policy source settings match ADR 0026")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
