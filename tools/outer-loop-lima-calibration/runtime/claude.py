from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Iterable

from lib.model import ContractError


TOOL_FREE_PROMPT = "Reply with exactly CALIBRATION_SMOKE_OK. Do not call any tool."


def login_command() -> list[str]:
    return ["claude", "auth", "login", "--claudeai"]


def smoke_command() -> list[str]:
    return [
        "claude",
        "--print",
        "--safe-mode",
        "--tools",
        "",
        "--strict-mcp-config",
        "--no-chrome",
        "--disable-slash-commands",
        "--no-session-persistence",
        "--output-format",
        "stream-json",
        "--verbose",
        TOOL_FREE_PROMPT,
    ]


@dataclass(frozen=True, slots=True)
class ToolEvent:
    name: str
    command: str | None


def _walk(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk(child)


def extract_tool_events(lines: Iterable[str]) -> tuple[ToolEvent, ...]:
    events: list[ToolEvent] = []
    for line in lines:
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ContractError("Claude stream emitted invalid JSONL") from exc
        for candidate in _walk(event):
            if candidate.get("type") != "tool_use":
                continue
            name = candidate.get("name")
            payload = candidate.get("input")
            if not isinstance(name, str) or not isinstance(payload, dict):
                raise ContractError("Claude tool event lacks name or input")
            command = payload.get("command")
            events.append(ToolEvent(name=name, command=command if isinstance(command, str) else None))
    return tuple(events)


def validate_tool_free_events(lines: Iterable[str]) -> None:
    materialized = tuple(lines)
    if extract_tool_events(materialized):
        raise ContractError("Claude smoke used a tool")
    saw_message = False
    for line in materialized:
        event = json.loads(line)
        for candidate in _walk(event):
            text = candidate.get("text")
            if text == "CALIBRATION_SMOKE_OK":
                saw_message = True
    if not saw_message:
        raise ContractError("Claude smoke did not produce the fixed response")


def validate_bash_probe_events(lines: Iterable[str], intended_argv: str) -> ToolEvent:
    events = extract_tool_events(lines)
    if len(events) != 1:
        raise ContractError("Claude probe must contain exactly one tool use")
    event = events[0]
    if event.name != "Bash" or event.command != intended_argv:
        raise ContractError("Claude probe tool or argv mutated")
    return event
