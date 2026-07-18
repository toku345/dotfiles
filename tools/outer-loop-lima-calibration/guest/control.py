#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys


NONCE_RE = re.compile(r"^[0-9a-f]{32}$")
STARTED_PREFIX = "OUTER_LOOP_RECEIPT_STARTED:"
COMPLETE_PREFIX = "OUTER_LOOP_RECEIPT_COMPLETE:"


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def emit(prefix: str, value: object) -> None:
    print(prefix + json.dumps(value, sort_keys=True, separators=(",", ":")), flush=True)


def classify(returncode: int, stderr: str) -> str:
    lowered = stderr.lower()
    if any(marker in lowered for marker in ("operation not permitted", "network is unreachable", "blocked by network", "permission denied")):
        return "DENIED_BY_SANDBOX"
    if returncode == 0:
        return "COMMAND_SUCCEEDED"
    if returncode < 0:
        return "COMMAND_SIGNALED"
    return "COMMAND_FAILED_AMBIGUOUS"


def main() -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--nonce", required=True)
    parser.add_argument("--destination", required=True, choices=("public", "host", "private", "peer", "local-ipc"))
    parser.add_argument("argv", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not NONCE_RE.fullmatch(args.nonce):
        parser.error("nonce must be 32 lowercase hex characters")
    argv = args.argv[1:] if args.argv[:1] == ["--"] else args.argv
    if not argv:
        parser.error("probe argv is required")
    argv_digest = hashlib.sha256(canonical(argv)).hexdigest()
    started = {
        "schema_version": 1,
        "nonce": args.nonce,
        "destination": args.destination,
        "argv_digest": argv_digest,
        "classification": "STARTED"
    }
    emit(STARTED_PREFIX, started)
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=30, check=False)
        classification = classify(result.returncode, result.stderr)
        returncode = result.returncode
    except subprocess.TimeoutExpired:
        classification = "COMMAND_TIMEOUT"
        returncode = 124
    complete = {
        "schema_version": 1,
        "nonce": args.nonce,
        "destination": args.destination,
        "argv_digest": argv_digest,
        "classification": classification,
        "exit_classification": "ZERO" if returncode == 0 else "NONZERO"
    }
    emit(COMPLETE_PREFIX, complete)
    return returncode


if __name__ == "__main__":
    sys.exit(main())
