#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

# The harness manifest rejects every unlisted runtime file. Disable bytecode
# writes before importing local modules so the CLI cannot dirty its own source
# tree before preflight validates and freezes it.
sys.dont_write_bytecode = True

from lib.model import ContractError
from lib.orchestrator import Orchestrator
from lib.paths import DEFAULT_LIMA_POOL_ROOT, STATE_ROOT


def add_run_id(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("run_id")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Fail-closed Private Lima pre-arm calibration",
        allow_abbrev=False,
    )
    parser.add_argument("--state-root", type=Path)
    parser.add_argument("--lima-pool-root", type=Path)
    commands = parser.add_subparsers(dest="command", required=True)

    init_parser = commands.add_parser("init", allow_abbrev=False)
    add_run_id(init_parser)
    init_parser.add_argument("--retention-deadline", required=True)

    preflight = commands.add_parser("preflight", allow_abbrev=False)
    add_run_id(preflight)

    approve = commands.add_parser("approve", allow_abbrev=False)
    approval_commands = approve.add_subparsers(dest="approval", required=True)
    pre_vm = approval_commands.add_parser("pre-vm", allow_abbrev=False)
    add_run_id(pre_vm)
    pre_auth = approval_commands.add_parser("pre-auth", allow_abbrev=False)
    add_run_id(pre_auth)
    pre_auth.add_argument(
        "--code-paste-feasibility",
        required=True,
        choices=("confirmed",),
    )
    pre_handoff = approval_commands.add_parser("pre-handoff", allow_abbrev=False)
    add_run_id(pre_handoff)
    pre_handoff.add_argument("direction", choices=("forward", "reverse"))
    final_seal = approval_commands.add_parser("final-seal", allow_abbrev=False)
    add_run_id(final_seal)

    provision = commands.add_parser("provision", allow_abbrev=False)
    add_run_id(provision)

    authenticate = commands.add_parser("authenticate", allow_abbrev=False)
    auth_commands = authenticate.add_subparsers(dest="authentication", required=True)
    runtime = auth_commands.add_parser("runtime", allow_abbrev=False)
    add_run_id(runtime)
    runtime.add_argument("runtime", choices=("codex", "claude"))

    run = commands.add_parser("run", allow_abbrev=False)
    run_commands = run.add_subparsers(dest="run_phase", required=True)
    isolation = run_commands.add_parser("isolation", allow_abbrev=False)
    add_run_id(isolation)
    sync_export = run_commands.add_parser("sync-export", allow_abbrev=False)
    add_run_id(sync_export)
    handoff_forward = run_commands.add_parser("handoff-forward", allow_abbrev=False)
    add_run_id(handoff_forward)
    handoff_reverse = run_commands.add_parser("handoff-reverse", allow_abbrev=False)
    add_run_id(handoff_reverse)
    restart = run_commands.add_parser("restart", allow_abbrev=False)
    add_run_id(restart)

    prepare_seal = commands.add_parser("prepare-seal", allow_abbrev=False)
    add_run_id(prepare_seal)
    seal = commands.add_parser("seal", allow_abbrev=False)
    add_run_id(seal)
    status = commands.add_parser("status", allow_abbrev=False)
    add_run_id(status)
    cleanup = commands.add_parser("cleanup", allow_abbrev=False)
    add_run_id(cleanup)
    cleanup.add_argument(
        "--cause",
        required=True,
        choices=("deadline", "abandonment", "exposure", "cohort-completion"),
    )
    verify_cleanup = commands.add_parser("verify-cleanup", allow_abbrev=False)
    add_run_id(verify_cleanup)
    verify_cleanup.add_argument("--revoke-human-confirmed", action="store_true")
    return parser


def dispatch(args: argparse.Namespace, orchestrator: Orchestrator) -> dict[str, object]:
    if args.command == "init":
        return orchestrator.init(args.run_id, args.retention_deadline)
    if args.command == "preflight":
        return orchestrator.preflight(args.run_id)
    if args.command == "provision":
        return orchestrator.provision(args.run_id)
    if args.command == "prepare-seal":
        return orchestrator.prepare_seal(args.run_id)
    if args.command == "seal":
        return orchestrator.seal(args.run_id)
    if args.command == "status":
        return orchestrator.status(args.run_id)
    if args.command == "cleanup":
        return orchestrator.cleanup(args.run_id, cause=args.cause)
    if args.command == "verify-cleanup":
        return orchestrator.verify_cleanup(
            args.run_id,
            revoke_human_confirmed=args.revoke_human_confirmed,
        )
    if args.command == "approve":
        if args.approval == "pre-vm":
            return orchestrator.approve_pre_vm(args.run_id)
        if args.approval == "pre-auth":
            return orchestrator.approve_pre_auth(
                args.run_id,
                code_paste_feasible=args.code_paste_feasibility == "confirmed",
            )
        if args.approval == "pre-handoff":
            return orchestrator.approve_pre_handoff(args.run_id, args.direction)
        if args.approval == "final-seal":
            return orchestrator.approve_final_seal(args.run_id)
    if args.command == "authenticate" and args.authentication == "runtime":
        return orchestrator.authenticate(args.run_id, args.runtime)
    if args.command == "run":
        if args.run_phase == "isolation":
            return orchestrator.isolation(args.run_id)
        if args.run_phase == "sync-export":
            return orchestrator.sync_export(args.run_id)
        if args.run_phase == "handoff-forward":
            return orchestrator.handoff(args.run_id, "forward")
        if args.run_phase == "handoff-reverse":
            return orchestrator.handoff(args.run_id, "reverse")
        if args.run_phase == "restart":
            return orchestrator.restart(args.run_id)
    raise ContractError("unreachable CLI route")


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        state_root = args.state_root if args.state_root is not None else STATE_ROOT
        if not state_root.is_absolute():
            raise ContractError("state root must be an absolute path")
        if args.lima_pool_root is None:
            if args.state_root is not None and state_root != STATE_ROOT:
                raise ContractError("custom state root requires --lima-pool-root")
            lima_pool_root = DEFAULT_LIMA_POOL_ROOT
        else:
            lima_pool_root = args.lima_pool_root
        if not lima_pool_root.is_absolute():
            raise ContractError("Lima pool root must be an absolute path")
        orchestrator = Orchestrator(
            harness_root=Path(__file__).resolve().parent,
            state_root=state_root,
            lima_pool_root=lima_pool_root,
        )
        result = dispatch(args, orchestrator)
    except ContractError as exc:
        print(
            json.dumps(
                {
                    "terminal_state": "BLOCKED",
                    "real_task_allowed": False,
                    "error": str(exc),
                },
                sort_keys=True,
            ),
            file=sys.stderr,
        )
        return 1
    except Exception as exc:
        exception_class = f"{type(exc).__module__}.{type(exc).__qualname__}"
        print(
            json.dumps(
                {
                    "terminal_state": "BLOCKED",
                    "real_task_allowed": False,
                    "error": "unexpected_internal_error",
                    "exception_class": exception_class,
                    "diagnostic_id": hashlib.sha256(exception_class.encode()).hexdigest()[:16],
                },
                sort_keys=True,
            ),
            file=sys.stderr,
        )
        return 1
    print(json.dumps(result, sort_keys=True, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
