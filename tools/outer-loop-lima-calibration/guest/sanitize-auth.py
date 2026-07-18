#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path


TMPFS_ROOT = Path("/dev/shm/outer-loop")
NONCE_RE = re.compile(r"^[0-9a-f]{32}$")
DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
STARTED_PREFIX = "OUTER_LOOP_RECEIPT_STARTED:"
COMPLETE_PREFIX = "OUTER_LOOP_RECEIPT_COMPLETE:"
DESTINATIONS = {"public", "host", "private", "peer", "local-ipc"}
RECEIPT_CLASSIFICATIONS = {
    "DENIED_BY_SANDBOX",
    "COMMAND_SUCCEEDED",
    "COMMAND_SIGNALED",
    "COMMAND_FAILED_AMBIGUOUS",
    "COMMAND_TIMEOUT",
}


def within_tmpfs(path: Path) -> bool:
    try:
        path.absolute().relative_to(TMPFS_ROOT)
        return True
    except ValueError:
        return False


def credential_metadata(path: Path) -> dict[str, object]:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise ValueError("credential node is not a regular non-link file")
    if stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1:
        raise ValueError("credential mode or link count is unsafe")
    return {
        "node_type": "regular",
        "uid": info.st_uid,
        "gid": info.st_gid,
        "mode": "0600",
        "nlink": 1,
    }


def walk(value: object):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def walk_strings(value: object):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from walk_strings(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk_strings(child)


def _receipt_markers(event: object) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    started: list[dict[str, object]] = []
    complete: list[dict[str, object]] = []
    for text in walk_strings(event):
        for line in text.splitlines():
            for prefix, destination in (
                (STARTED_PREFIX, started),
                (COMPLETE_PREFIX, complete),
            ):
                marker = line.find(prefix)
                if marker < 0:
                    continue
                try:
                    value = json.loads(line[marker + len(prefix):])
                except json.JSONDecodeError as exc:
                    raise ValueError("probe receipt marker contained invalid JSON") from exc
                if not isinstance(value, dict):
                    raise ValueError("probe receipt marker was not an object")
                destination.append(value)
    return started, complete


def _validate_receipt(
    value: dict[str, object],
    *,
    expected_nonce: str,
    expected_destination: str,
    started: bool,
) -> None:
    expected_classification = "STARTED" if started else value.get("classification")
    if (
        value.get("schema_version") != 1
        or value.get("nonce") != expected_nonce
        or value.get("destination") != expected_destination
        or not isinstance(value.get("argv_digest"), str)
        or not DIGEST_RE.fullmatch(value["argv_digest"])
        or value.get("classification") != expected_classification
    ):
        raise ValueError("probe receipt identity mismatch")
    if started:
        return
    if value.get("classification") not in RECEIPT_CLASSIFICATIONS:
        raise ValueError("probe receipt classification was not allowlisted")
    expected_exit = "ZERO" if value.get("classification") == "COMMAND_SUCCEEDED" else "NONZERO"
    if value.get("exit_classification") != expected_exit:
        raise ValueError("probe receipt exit classification mismatch")


def smoke_classification(runtime: str, raw: str) -> dict[str, object]:
    saw_message = False
    tool_calls = 0
    for line in raw.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError("smoke stream contained invalid JSONL") from exc
        if not isinstance(event, dict):
            raise ValueError("smoke event was not an object")
        for candidate in walk(event):
            if runtime == "codex":
                item = candidate.get("item")
                if isinstance(item, dict):
                    if item.get("type") in {
                        "command_execution",
                        "file_change",
                        "mcp_tool_call",
                        "web_search",
                        "dynamic_tool_call",
                    }:
                        tool_calls += 1
                    if item.get("type") == "agent_message" and item.get("text") == "CALIBRATION_SMOKE_OK":
                        saw_message = True
            else:
                if candidate.get("type") == "tool_use":
                    tool_calls += 1
                if candidate.get("text") == "CALIBRATION_SMOKE_OK":
                    saw_message = True
    if tool_calls or not saw_message:
        raise ValueError("tool-free smoke classification failed")
    return {
        "schema_version": 1,
        "runtime": runtime,
        "smoke": "CALIBRATION_SMOKE_OK",
        "tool_calls": 0,
    }


def probe_classification(
    runtime: str,
    raw: str,
    intended_command: str,
    expected_nonce: str,
    expected_destination: str,
) -> dict[str, object]:
    commands: list[tuple[str, str]] = []
    started_receipts: list[dict[str, object]] = []
    complete_receipts: list[dict[str, object]] = []
    for line in raw.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError("probe stream contained invalid JSONL") from exc
        started, complete = _receipt_markers(event)
        started_receipts.extend(started)
        complete_receipts.extend(complete)
        for candidate in walk(event):
            if runtime == "codex":
                item = candidate.get("item")
                if isinstance(item, dict) and item.get("type") == "command_execution":
                    command = item.get("command")
                    if isinstance(command, str):
                        commands.append(("command_execution", command))
            elif candidate.get("type") == "tool_use" and candidate.get("name") == "Bash":
                payload = candidate.get("input")
                if isinstance(payload, dict) and isinstance(payload.get("command"), str):
                    commands.append(("Bash", payload["command"]))
    if len(commands) != 1 or commands[0][1] != intended_command:
        raise ValueError("probe command was refused, omitted, duplicated, or mutated")
    if len(started_receipts) != 1 or len(complete_receipts) != 1:
        raise ValueError("probe receipt was missing or duplicated")
    _validate_receipt(
        started_receipts[0],
        expected_nonce=expected_nonce,
        expected_destination=expected_destination,
        started=True,
    )
    _validate_receipt(
        complete_receipts[0],
        expected_nonce=expected_nonce,
        expected_destination=expected_destination,
        started=False,
    )
    return {
        "schema_version": 1,
        "runtime": runtime,
        "tool": commands[0][0],
        "command_digest": hashlib.sha256(intended_command.encode()).hexdigest(),
        "exact_command": True,
        "receipt": complete_receipts[0],
    }


def auth_classification(runtime: str, raw: str, credential: Path) -> dict[str, object]:
    lowered = raw.lower()
    if runtime == "codex":
        authenticated = "logged in" in lowered and "chatgpt" in lowered
        method = "chatgpt_device"
    else:
        authenticated = ("logged in" in lowered or "authenticated" in lowered) and "claude.ai" in lowered
        method = "claudeai_oauth"
    if not authenticated:
        raise ValueError("authentication classification was not allowlisted")
    return {
        "schema_version": 1,
        "runtime": runtime,
        "authenticated": True,
        "authentication_method": method,
        "credential": credential_metadata(credential),
    }


def main() -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--kind", required=True, choices=("auth", "smoke", "probe"))
    parser.add_argument("--runtime", required=True, choices=("codex", "claude"))
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--credential", type=Path)
    parser.add_argument("--intended-command")
    parser.add_argument("--expected-nonce")
    parser.add_argument("--expected-destination", choices=tuple(sorted(DESTINATIONS)))
    args = parser.parse_args()
    if not within_tmpfs(args.input) or not within_tmpfs(args.output):
        parser.error("raw and sanitized files must remain under /dev/shm/outer-loop")
    try:
        raw = args.input.read_text(encoding="utf-8", errors="strict")
        if args.kind == "smoke":
            output = smoke_classification(args.runtime, raw)
        elif args.kind == "probe":
            if (
                not args.intended_command
                or not isinstance(args.expected_nonce, str)
                or not NONCE_RE.fullmatch(args.expected_nonce)
                or args.expected_destination not in DESTINATIONS
            ):
                raise ValueError("intended command and receipt identity are required for probe classification")
            output = probe_classification(
                args.runtime,
                raw,
                args.intended_command,
                args.expected_nonce,
                args.expected_destination,
            )
        else:
            if args.credential is None:
                raise ValueError("credential path is required for auth classification")
            output = auth_classification(args.runtime, raw, args.credential)
        descriptor = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            os.write(descriptor, (json.dumps(output, sort_keys=True, separators=(",", ":")) + "\n").encode())
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        args.input.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as exc:
        print(f"sanitization failed: {exc}", file=sys.stderr)
        sys.exit(1)
