#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path


NONCE_RE = re.compile(r"^[0-9a-f]{32}$")
RECEIPT_ROOT = Path("/run/outer-loop-probe/receipts")


def canonical(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def write_once(path: Path, value: object) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        os.write(descriptor, canonical(value))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


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
    start = RECEIPT_ROOT / f"{args.nonce}.started.json"
    complete = RECEIPT_ROOT / f"{args.nonce}.complete.json"
    write_once(start, {
        "schema_version": 1,
        "nonce": args.nonce,
        "destination": args.destination,
        "argv_digest": argv_digest,
        "classification": "STARTED"
    })
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=30, check=False)
        classification = classify(result.returncode, result.stderr)
        returncode = result.returncode
    except subprocess.TimeoutExpired:
        classification = "COMMAND_TIMEOUT"
        returncode = 124
    write_once(complete, {
        "schema_version": 1,
        "nonce": args.nonce,
        "destination": args.destination,
        "argv_digest": argv_digest,
        "classification": classification,
        "exit_classification": "ZERO" if returncode == 0 else "NONZERO"
    })
    return returncode


if __name__ == "__main__":
    sys.exit(main())
