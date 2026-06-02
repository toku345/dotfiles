#!/usr/bin/env python3
"""Negative tests for the Claude/Codex update policy verifier."""

from __future__ import annotations

import copy
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
from types import ModuleType


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
VERIFY_SCRIPT = REPO_ROOT / "tests" / "codex" / "verify_claude_update_policy.py"
SETTINGS = REPO_ROOT / "private_dot_claude" / "settings.json"


def load_verifier() -> ModuleType:
    spec = importlib.util.spec_from_file_location("verify_claude_update_policy", VERIFY_SCRIPT)
    if spec is None or spec.loader is None:
        raise AssertionError("failed to load verify_claude_update_policy.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def assert_fails_closed(name: str, data: object, expected: str, verifier: ModuleType) -> None:
    failures = verifier.validate_update_policy(data)
    if not failures:
        raise AssertionError(f"{name}: verifier unexpectedly passed")
    if expected not in failures:
        raise AssertionError(f"{name}: expected {expected!r}, got {failures!r}")


def main() -> None:
    verifier = load_verifier()
    baseline = json.loads(SETTINGS.read_text(encoding="utf-8"))
    baseline_failures = verifier.validate_update_policy(baseline)
    if baseline_failures:
        raise AssertionError(f"baseline verifier failed: {baseline_failures!r}")

    mutations = []

    data = copy.deepcopy(baseline)
    data["env"].pop("DISABLE_AUTOUPDATER")
    mutations.append(("missing updater kill switch", data, 'env.DISABLE_AUTOUPDATER must be "1"'))

    data = copy.deepcopy(baseline)
    data["env"]["FORCE_AUTOUPDATE_PLUGINS"] = "1"
    mutations.append(("plugin override enabled", data, "env.FORCE_AUTOUPDATE_PLUGINS must be absent"))

    data = copy.deepcopy(baseline)
    data["autoUpdatesChannel"] = "latest"
    mutations.append(("wrong update channel", data, 'autoUpdatesChannel must be "stable"'))

    data = copy.deepcopy(baseline)
    data["extraKnownMarketplaces"].pop("openai-codex")
    mutations.append(
        (
            "missing Codex marketplace",
            data,
            "extraKnownMarketplaces.openai-codex must be present",
        )
    )

    data = copy.deepcopy(baseline)
    data["extraKnownMarketplaces"]["openai-codex"]["autoUpdate"] = True
    mutations.append(
        (
            "Codex marketplace auto-update enabled",
            data,
            "extraKnownMarketplaces.openai-codex.autoUpdate must be false",
        )
    )

    data = copy.deepcopy(baseline)
    data["extraKnownMarketplaces"]["openai-codex"]["source"]["source"] = "local"
    mutations.append(
        (
            "wrong Codex marketplace source type",
            data,
            'extraKnownMarketplaces.openai-codex.source.source must be "github"',
        )
    )

    data = copy.deepcopy(baseline)
    data["extraKnownMarketplaces"]["openai-codex"]["source"]["repo"] = "example/untrusted"
    mutations.append(
        (
            "wrong Codex marketplace repo",
            data,
            'extraKnownMarketplaces.openai-codex.source.repo must be "openai/codex-plugin-cc"',
        )
    )

    data = copy.deepcopy(baseline)
    data["extraKnownMarketplaces"]["openai-codex"]["source"]["ref"] = "main"
    mutations.append(
        (
            "ambiguous Codex marketplace source",
            data,
            'extraKnownMarketplaces.openai-codex.source must contain only "source" and "repo"',
        )
    )

    data = copy.deepcopy(baseline)
    data["enabledPlugins"]["codex@openai-codex"] = False
    mutations.append(
        (
            "Codex plugin disabled",
            data,
            'enabledPlugins."codex@openai-codex" must be true',
        )
    )

    data = copy.deepcopy(baseline)
    data["enabledPlugins"]["codex@untrusted-marketplace"] = True
    mutations.append(
        (
            "untrusted Codex plugin enabled",
            data,
            'enabledPlugins must not enable Codex plugins outside "codex@openai-codex"',
        )
    )

    for name, data, expected in mutations:
        assert_fails_closed(name, data, expected, verifier)

    with tempfile.TemporaryDirectory() as tmpdir:
        settings = pathlib.Path(tmpdir) / "settings.json"
        data = copy.deepcopy(baseline)
        data["autoUpdatesChannel"] = "latest"
        settings.write_text(json.dumps(data), encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(VERIFY_SCRIPT), "--settings", str(settings)],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode != 1:
            raise AssertionError(
                f"CLI negative test: expected exit 1, got {result.returncode}; "
                f"stdout={result.stdout!r} stderr={result.stderr!r}"
            )
        if 'ERROR: autoUpdatesChannel must be "stable"' not in result.stderr:
            raise AssertionError(f"CLI negative test: unexpected stderr {result.stderr!r}")

    print("OK: Claude/Codex update policy negative tests passed")


if __name__ == "__main__":
    main()
