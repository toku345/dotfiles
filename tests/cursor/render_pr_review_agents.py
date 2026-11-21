#!/usr/bin/env python3
"""Render Cursor pr-review agents from the Codex toml files.

The Codex toml files stay the specialist source. This script writes the
Cursor markdown those toml files imply, and copies the shared gate files
the Cursor skill executes. --check fails when a committed file drifts.
"""

from __future__ import annotations

import argparse
import pathlib
import sys
import tomllib


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
TOML_DIR = REPO_ROOT / "private_dot_codex" / "agents"
CODEX_SKILL = REPO_ROOT / "private_dot_codex" / "skills" / "pr-review"
CURSOR_SKILL = REPO_ROOT / ".cursor" / "skills" / "pr-review"
CURSOR_AGENTS = REPO_ROOT / ".cursor" / "agents"
DOT_CURSOR = REPO_ROOT / "dot_cursor"

SHARED = {
    "references/review-criteria.md": CODEX_SKILL / "references" / "review-criteria.md",
    "references/severity-rules.json": CODEX_SKILL / "references" / "severity-rules.json",
    "references/finding-verifier-contract.json": (
        CODEX_SKILL / "references" / "finding-verifier-contract.json"
    ),
    "scripts/validate_finding_evidence.py": (
        CODEX_SKILL / "scripts" / "validate_finding_evidence.py"
    ),
}

NOT_COPIED = (
    "references/base-resolution-runtime-contract.json",
    "references/v2-runtime-contract.json",
    "scripts/routing-flags.sh",
)

# The generated agent markdown quotes each toml header, and those headers
# point at the license files beside the toml. Keep the same files beside
# both Cursor copies so the pointer stays true.
LICENSE_FILES = (
    "LICENSE-claude-code-security-review",
    "LICENSE-claude-plugins-official",
    "LICENSE-codex-plugin-cc",
    "NOTICE-codex-plugin-cc",
)


def toml_files() -> list[pathlib.Path]:
    files = sorted(TOML_DIR.glob("*.toml"))
    if not files:
        raise SystemExit(f"no toml files in {TOML_DIR}")
    return files


def comment_header(text: str) -> str:
    header: list[str] = []
    for line in text.splitlines():
        if line.startswith("#") or line.strip() == "":
            header.append(line)
            continue
        break
    body = "\n".join(header).strip("\n")
    if "-->" in body:
        raise SystemExit("toml header contains --> and cannot sit in an HTML comment")
    return body


def render_agent(path: pathlib.Path) -> str:
    raw = path.read_text()
    data = tomllib.loads(raw)
    name = data["name"]
    if name != path.stem:
        raise SystemExit(f"{path} name {name!r} does not match the file stem")
    instructions = data["developer_instructions"]
    if not instructions.endswith("\n"):
        instructions += "\n"
    header = comment_header(raw)
    description = (
        f"pr-review specialist {name}. Launch only from the pr-review skill."
    )
    return (
        "---\n"
        f"name: {name}\n"
        f"description: {description}\n"
        "model: inherit\n"
        "readonly: true\n"
        "---\n"
        "\n"
        "<!--\n"
        f"{header}\n"
        "-->\n"
        "\n"
        "Do not launch subagents.\n"
        "\n"
        f"{instructions}"
    )


def skill_template(rel: str) -> str:
    comment = (
        "{{- /* canonical: .cursor/skills/pr-review/"
        + rel
        + " — regenerate with tests/cursor/render_pr_review_agents.py --write */ -}}\n"
    )
    include = '{{ include ".cursor/skills/pr-review/' + rel + '" -}}\n'
    return comment + include


def user_agent_template(name: str) -> str:
    comment = (
        "{{- /* canonical: .cursor/agents/"
        + name
        + ".md — generated from private_dot_codex/agents/"
        + name
        + ".toml */ -}}\n"
    )
    include = '{{ include ".cursor/agents/' + name + '.md" -}}\n'
    return comment + include


def expected_files() -> dict[pathlib.Path, str]:
    files: dict[pathlib.Path, str] = {}
    for toml_path in toml_files():
        rendered = render_agent(toml_path)
        files[CURSOR_SKILL / "agents" / f"{toml_path.stem}.md"] = rendered
        files[CURSOR_AGENTS / f"{toml_path.stem}.md"] = rendered
        files[DOT_CURSOR / "agents" / f"{toml_path.stem}.md.tmpl"] = user_agent_template(
            toml_path.stem
        )
        rel = f"agents/{toml_path.stem}.md"
        files[DOT_CURSOR / "skills" / "pr-review" / f"{rel}.tmpl"] = skill_template(rel)
    for name in LICENSE_FILES:
        source = TOML_DIR / name
        text = source.read_text()
        files[CURSOR_SKILL / "agents" / name] = text
        files[CURSOR_AGENTS / name] = text
        files[DOT_CURSOR / "agents" / f"{name}.tmpl"] = (
            "{{- /* canonical: private_dot_codex/agents/"
            + name
            + " */ -}}\n"
            + '{{ include "private_dot_codex/agents/'
            + name
            + '" -}}\n'
        )
        rel = f"agents/{name}"
        files[DOT_CURSOR / "skills" / "pr-review" / f"{rel}.tmpl"] = skill_template(rel)
    for rel, source in SHARED.items():
        files[CURSOR_SKILL / rel] = source.read_text()
        files[DOT_CURSOR / "skills" / "pr-review" / f"{rel}.tmpl"] = skill_template(rel)
    return files


def check() -> int:
    expected = expected_files()
    failed = False
    for path, content in sorted(expected.items()):
        if not path.is_file():
            print(f"missing {path.relative_to(REPO_ROOT)}", file=sys.stderr)
            failed = True
            continue
        actual = path.read_text()
        if actual != content:
            print(f"drift {path.relative_to(REPO_ROOT)}", file=sys.stderr)
            failed = True
    for rel in NOT_COPIED:
        path = CURSOR_SKILL / rel
        if path.exists():
            print(f"unexpected {path.relative_to(REPO_ROOT)}", file=sys.stderr)
            failed = True
    if failed:
        print(
            "rerun: python3 tests/cursor/render_pr_review_agents.py --write",
            file=sys.stderr,
        )
        return 1
    print(f"OK: {len(expected)} Cursor pr-review files match the Codex sources")
    return 0


def write() -> int:
    expected = expected_files()
    for path, content in expected.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    return check()


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    args = parser.parse_args()
    if args.write:
        return write()
    return check()


if __name__ == "__main__":
    raise SystemExit(main())
