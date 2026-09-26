#!/usr/bin/env python3
"""Read live TOML on stdin; emit a fully validated update on stdout.

Usage: merge.py [--policy policy.toml]
"""

from __future__ import annotations

import copy
import importlib.metadata
import math
import pathlib
import re
import sys
import tomllib
from collections.abc import MutableMapping
from typing import Any

from config_policy import PolicyError, load_policy


PROJECT = pathlib.Path(__file__).resolve().parent


def check_environment() -> None:
    """Check the one pinned runtime dependency without resolving or installing."""
    try:
        project = tomllib.loads((PROJECT / "pyproject.toml").read_text())
        lock = tomllib.loads((PROJECT / "uv.lock").read_text())
        packages = [p for p in lock["package"] if p["name"] == "tomlkit"]
        if len(packages) != 1:
            raise ValueError("ambiguous lock")
        version = packages[0]["version"]
        if project["project"]["dependencies"] != [f"tomlkit=={version}"]:
            raise ValueError("manifest and lock disagree")
        if importlib.metadata.version("tomlkit") != version:
            raise ValueError("environment and lock disagree")
    except (OSError, UnicodeError, ValueError, KeyError, TypeError,
            importlib.metadata.PackageNotFoundError) as exc:
        raise PolicyError("dependency mismatch; run sh scripts/codex-config/setup.sh") from exc


def equal(left: Any, right: Any) -> bool:
    """Compare TOML types too (Python otherwise treats True and 1 as equal)."""
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(equal(left[k], right[k]) for k in left)
    if isinstance(left, list):
        return len(left) == len(right) and all(equal(a, b) for a, b in zip(left, right))
    if isinstance(left, float) and math.isnan(left) and math.isnan(right):
        return True
    return left == right


def parent(table: MutableMapping, path: tuple[str, ...], make_table) -> MutableMapping:
    for key in path[:-1]:
        if key not in table:
            table[key] = make_table()
        table = table[key]
        if not isinstance(table, MutableMapping):
            raise PolicyError("policy path collides with a non-table value")
    return table


def marker_blocks(text: str) -> list[str]:
    """Protect complete installer-owned blocks, not just their marker lines."""
    lines = text.splitlines(keepends=True)
    blocks = []
    start = None
    name = None
    for i, line in enumerate(lines):
        opening = re.fullmatch(r"\s*# >>> (.+) >>>\s*", line)
        closing = re.fullmatch(r"\s*# <<< (.+) <<<\s*", line)
        if opening:
            if start is not None:
                raise PolicyError("nested installer markers")
            start, name = i, opening[1]
        elif closing:
            if start is None or closing[1] != name:
                raise PolicyError("unmatched installer markers")
            blocks.append("".join(lines[start:i + 1]))
            start, name = None, None
    if start is not None:
        raise PolicyError("unclosed installer markers")
    return blocks


def set_value(document: MutableMapping, path: tuple[str, ...], value: Any) -> None:
    import tomlkit

    target = document
    for index, key in enumerate(path[:-1]):
        if key not in target:
            # A header inside a dotted-key table can capture later root keys.
            # Keep additions to such implicit tables in dotted notation.
            if isinstance(target, tomlkit.items.Table) and target.is_super_table():
                target.add(tomlkit.key(list(path[index:])), copy.deepcopy(value))
                return
            target[key] = (
                tomlkit.inline_table() if isinstance(target, tomlkit.items.InlineTable)
                else tomlkit.table()
            )
        target = target[key]
    target[path[-1]] = copy.deepcopy(value)


def root_values_prefix(document: MutableMapping, policy: dict) -> str:
    """Render root-level policy rows whose key is absent, for the file header.

    A new root-level key must not be placed just before the first table: that
    position can sit inside an installer-owned block, which the caller's
    integrity check rejects. Writing the key ahead of every existing item keeps
    it at the top level and leaves such a block untouched.
    """
    import tomlkit

    prefix = tomlkit.document()
    for rows in policy.values():
        for path, value in rows.items():
            if len(path) == 1 and path[0] not in document:
                prefix[path[0]] = copy.deepcopy(value)
    return tomlkit.dumps(prefix) if len(prefix) > 0 else ""


def merge(text: str, policy: dict) -> tuple[str, list[str]]:
    import tomlkit

    document = tomlkit.parse(text)
    prefix = root_values_prefix(document, policy)
    if prefix:
        text = prefix + ("\n" + text if text else "")
        document = tomlkit.parse(text)
    expected = copy.deepcopy(document.unwrap())
    blocks = marker_blocks(text)
    warnings = []
    changed = False
    for mode, rows in policy.items():
        for path, value in rows.items():
            wanted = parent(expected, path, dict)
            key = path[-1]
            if key in wanted:
                if isinstance(wanted[key], dict) or (
                    isinstance(wanted[key], list) and any(isinstance(v, dict) for v in wanted[key])
                ):
                    raise PolicyError("policy value collides with a table")
                if equal(wanted[key], value):
                    continue
                if mode == "seed":
                    warnings.append(f"seed {'.'.join(path)} differs from the declared value; keeping live value")
                    continue
            set_value(document, path, value)
            wanted[key] = copy.deepcopy(value)
            changed = True

    output = tomlkit.dumps(document) if changed else text
    if not equal(tomlkit.parse(output).unwrap(), expected):
        raise PolicyError("generated TOML failed value preservation checks")
    if marker_blocks(output) != blocks:
        raise PolicyError("update would change an installer-owned block")
    return output, warnings


def select_policy(argv: list[str]) -> str:
    """Return the policy file name requested on the command line."""
    if not argv:
        return "policy.toml"
    if len(argv) == 2 and argv[0] == "--policy":
        name = argv[1]
        if not re.fullmatch(r"policy[a-z0-9-]*\.toml", name):
            raise PolicyError("invalid policy name")
        path = PROJECT / name
        if path.resolve().parent != PROJECT or not path.is_file():
            raise PolicyError("policy file not found")
        return name
    raise PolicyError("unsupported arguments")


def main() -> int:
    try:
        check_environment()
        policy = load_policy(PROJECT / select_policy(sys.argv[1:]))
        text = sys.stdin.buffer.read().decode("utf-8")
        output, warnings = merge(text, policy)
    except Exception as exc:
        # Parser errors may embed live values. Only our controlled messages
        # are safe diagnostics; no partial output is ever published.
        message = str(exc) if isinstance(exc, PolicyError) else "cannot safely update TOML; check syntax and structure"
        print(f"codex-config: {message}", file=sys.stderr)
        return 1
    for warning in warnings:
        print(f"codex-config: {warning}", file=sys.stderr)
    sys.stdout.buffer.write(output.encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
