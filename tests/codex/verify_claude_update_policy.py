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


def main() -> int:
    data = json.loads(SETTINGS.read_text())
    failures: list[str] = []

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
        elif marketplace.get("autoUpdate") is not False:
            failures.append("extraKnownMarketplaces.openai-codex.autoUpdate must be false")

    if failures:
        for failure in failures:
            print(f"ERROR: {failure}", file=sys.stderr)
        return 1

    print("OK: Claude/Codex update policy settings are enforced")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
