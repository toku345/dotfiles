from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any, Iterable, Mapping

from lib.identities import EffectiveValue, compare_effective_seed, flatten_mapping, load_toml_flat
from lib.model import ContractError


FIXED_HARMLESS_CWD = "/home/calibration/workspace/harmless"
TOOL_FREE_PROMPT = "Reply with exactly CALIBRATION_SMOKE_OK. Do not call any tool."
SYSTEM_CONFIG = "/etc/codex/config.toml"
SYSTEM_REQUIREMENTS = "/etc/codex/requirements.toml"


def login_command() -> list[str]:
    return ["codex", "login", "--device-auth"]


def smoke_command() -> list[str]:
    return [
        "codex",
        "exec",
        "--json",
        "--ephemeral",
        "--skip-git-repo-check",
        "--cd",
        FIXED_HARMLESS_CWD,
        TOOL_FREE_PROMPT,
    ]


def _request_lines(cwd: str) -> str:
    messages = (
        {
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "outer_loop_lima_calibration",
                    "title": "Private Lima calibration",
                    "version": "1",
                },
                "capabilities": {"experimentalApi": True},
            },
        },
        {"method": "initialized", "params": {}},
        {"id": 2, "method": "config/read", "params": {"cwd": cwd, "includeLayers": True}},
        {"id": 3, "method": "configRequirements/read", "params": {}},
    )
    return "".join(json.dumps(message, separators=(",", ":")) + "\n" for message in messages)


def read_effective_config(
    binary: str = "codex", cwd: str = FIXED_HARMLESS_CWD, timeout: int = 20
) -> tuple[dict[str, Any], dict[str, Any]]:
    try:
        result = subprocess.run(
            [binary, "app-server", "--strict-config", "--listen", "stdio://"],
            input=_request_lines(cwd),
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise ContractError("Codex app-server introspection failed") from exc
    responses: dict[int, dict[str, Any]] = {}
    for raw_line in result.stdout.splitlines():
        try:
            message = json.loads(raw_line)
        except json.JSONDecodeError as exc:
            raise ContractError("Codex app-server emitted non-JSON stdout") from exc
        if isinstance(message, dict) and isinstance(message.get("id"), int):
            responses[message["id"]] = message
    for request_id, method in ((1, "initialize"), (2, "config/read"), (3, "configRequirements/read")):
        response = responses.get(request_id)
        if response is None or "error" in response or "result" not in response:
            raise ContractError(f"Codex method unavailable or failed: {method}")
    if result.returncode not in (0, -15):
        raise ContractError(f"Codex app-server exited unexpectedly: {result.returncode}")
    return responses[2]["result"], responses[3]["result"]


def _origin_name(metadata: Mapping[str, Any]) -> Mapping[str, Any]:
    name = metadata.get("name")
    return name if isinstance(name, dict) else {}


def normalize_config_response(response: Mapping[str, Any]) -> dict[str, EffectiveValue]:
    config = response.get("config")
    origins = response.get("origins")
    layers = response.get("layers")
    if not isinstance(config, dict) or not isinstance(origins, dict) or not isinstance(layers, list):
        raise ContractError("Codex config/read omitted config, origins, or layers")

    for layer in layers:
        if not isinstance(layer, dict):
            raise ContractError("invalid Codex config layer")
        name = layer.get("name")
        if isinstance(name, dict) and name.get("type") in {
            "enterpriseManaged",
            "legacyManagedConfigTomlFromFile",
            "legacyManagedConfigTomlFromMdm",
        }:
            raise ContractError(f"unexpected composed Codex layer: {name.get('type')}")

    flattened = flatten_mapping(config)
    normalized: dict[str, EffectiveValue] = {}
    for key, value in flattened.items():
        metadata = origins.get(key)
        if not isinstance(metadata, dict):
            continue
        name = _origin_name(metadata)
        if name.get("type") == "system" and name.get("file") == SYSTEM_CONFIG:
            origin = "system:/etc/codex/config.toml"
        else:
            origin = json.dumps(name, sort_keys=True, separators=(",", ":"))
        normalized[key] = EffectiveValue(value=value, origin=origin)
    return normalized


def _snake_to_camel(value: str) -> str:
    head, *tail = value.split("_")
    return head + "".join(piece[:1].upper() + piece[1:] for piece in tail)


def normalize_requirements_seed(seed: Mapping[str, Any]) -> dict[str, Any]:
    normalized: dict[str, Any] = {}
    for key, value in seed.items():
        pieces = key.split(".")
        if pieces[0] == "features":
            path = ".".join(("featureRequirements", *pieces[1:]))
        else:
            path = ".".join((_snake_to_camel(pieces[0]), *pieces[1:]))
        normalized[path] = value
    return normalized


def validate_effective_policy(
    config_response: Mapping[str, Any],
    requirements_response: Mapping[str, Any],
    config_seed: Path,
    requirements_seed: Path,
) -> None:
    expected_config = load_toml_flat(config_seed)
    observed_config = normalize_config_response(config_response)
    compare_effective_seed(
        expected_config,
        observed_config,
        expected_origin="system:/etc/codex/config.toml",
    )

    requirements = requirements_response.get("requirements")
    if not isinstance(requirements, dict):
        raise ContractError("Codex configRequirements/read returned no requirements")
    expected_requirements = normalize_requirements_seed(load_toml_flat(requirements_seed))
    observed_requirements = {
        key: value for key, value in flatten_mapping(requirements).items() if value is not None
    }
    missing = sorted(set(expected_requirements).difference(observed_requirements))
    mismatched = sorted(
        key
        for key in set(expected_requirements).intersection(observed_requirements)
        if expected_requirements[key] != observed_requirements[key]
    )
    unexpected = sorted(set(observed_requirements).difference(expected_requirements))
    if missing or mismatched or unexpected:
        raise ContractError(
            "effective requirements mismatch "
            f"missing={missing} values={mismatched} unexpected={unexpected}"
        )


def validate_tool_free_events(lines: Iterable[str]) -> None:
    saw_message = False
    for line in lines:
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ContractError("Codex smoke emitted invalid JSONL") from exc
        if not isinstance(event, dict):
            raise ContractError("Codex smoke event is not an object")
        item = event.get("item")
        if isinstance(item, dict):
            item_type = item.get("type")
            if item_type in {
                "command_execution",
                "file_change",
                "mcp_tool_call",
                "web_search",
                "dynamic_tool_call",
            }:
                raise ContractError(f"Codex smoke used a tool: {item_type}")
            if item_type == "agent_message" and item.get("text") == "CALIBRATION_SMOKE_OK":
                saw_message = True
    if not saw_message:
        raise ContractError("Codex smoke did not produce the fixed response")
