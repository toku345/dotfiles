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
SETTINGS = REPO_ROOT / "private_dot_claude" / "settings.json"


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
    elif enabled_plugins.get("codex@openai-codex") is not True:
        failures.append('enabledPlugins."codex@openai-codex" must be true')

    return failures


def main() -> int:
    data = json.loads(SETTINGS.read_text())
    failures = validate_update_policy(data)

    if failures:
        for failure in failures:
            print(f"ERROR: {failure}", file=sys.stderr)
        return 1

    print("OK: Claude/Codex update policy settings are enforced")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
