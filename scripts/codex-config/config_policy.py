"""Shared, stdlib-only reader for the modifier and static bundle verifier."""

from __future__ import annotations

import pathlib
import tomllib
from typing import Any


class PolicyError(ValueError):
    """An input cannot be safely updated; messages never contain config values."""


def load_policy(path: pathlib.Path) -> dict[str, dict[tuple[str, ...], Any]]:
    try:
        raw = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as exc:
        raise PolicyError("cannot read a valid policy TOML") from exc
    if set(raw) != {"pin", "seed"}:
        raise PolicyError("policy must contain exactly pin and seed tables")

    def scalar(value: Any) -> bool:
        return type(value) in (str, bool, int, float) or (
            isinstance(value, list) and all(scalar(item) for item in value)
        )

    def flatten(table: Any, prefix: tuple[str, ...], rows: dict) -> None:
        if not isinstance(table, dict):
            raise PolicyError("policy tables must be tables")
        if not table and prefix:
            # Only the top-level [pin] / [seed] tables may be empty. An empty
            # nested table is a declaration mistake that flatten would
            # otherwise drop without any effect.
            raise PolicyError("nested policy tables must be non-empty")
        for key, value in table.items():
            if not key or any(ord(c) < 32 or ord(c) == 127 for c in key):
                raise PolicyError("policy keys must be non-empty and printable")
            path = (*prefix, key)
            if isinstance(value, dict):
                flatten(value, path, rows)
            elif scalar(value):
                rows[path] = value
            else:
                raise PolicyError("policy values must be scalars or scalar arrays")

    result: dict[str, dict[tuple[str, ...], Any]] = {"pin": {}, "seed": {}}
    for mode in result:
        flatten(raw[mode], (), result[mode])
    if not result["pin"] and not result["seed"]:
        raise PolicyError("policy must declare at least one value")
    paths = [*result["pin"], *result["seed"]]
    for i, left in enumerate(paths):
        for right in paths[i + 1:]:
            if left == right[:len(left)] or right == left[:len(right)]:
                raise PolicyError("policy paths overlap")
    return result
