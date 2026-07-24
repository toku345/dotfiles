#!/usr/bin/env python3
"""Executable contract tests for pr-review base resolution.

The orchestrator lives in SKILL.md, so this harness models the externally
observable command/control-plane decisions and replays sanitized traces. Live
Codex smoke remains responsible for proving that the model emits those tool
calls.
"""

from __future__ import annotations

import dataclasses
import enum
import json
import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SKILL_DIR = REPO_ROOT / "private_dot_codex" / "skills" / "pr-review"
CONTRACT_PATH = SKILL_DIR / "references" / "base-resolution-runtime-contract.json"
FIXTURE_PATH = (
    REPO_ROOT
    / "tests"
    / "codex"
    / "fixtures"
    / "pr_review_base_resolution_escalation.json"
)
CONTRACT = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
if CONTRACT.get("sentinel") != "PR_REVIEW_BASE_RESOLUTION_CONTRACT_V1":
    raise AssertionError(f"{CONTRACT_PATH}: unsupported base-resolution contract")

DENIAL_RESULTS = {
    "transport-denial",
    "transport-denial-with-credential-text",
    "filesystem-denial",
}


class ReplayState(enum.Enum):
    PR_VIEW = "pr-view"
    PR_VIEW_DEBUG = "pr-view-debug"
    PR_VIEW_ELEVATED = "pr-view-elevated"
    FETCH_BRANCH = "fetch-branch"
    FETCH_BRANCH_ELEVATED = "fetch-branch-elevated"
    VERIFY_OID = "verify-oid"
    CONTINUE = "continue"
    FATAL = "fatal"


@dataclasses.dataclass(frozen=True)
class Invocation:
    argv: tuple[str, ...]
    cwd: str
    env: tuple[tuple[str, str], ...]

    @classmethod
    def from_dict(cls, raw: dict) -> "Invocation":
        return cls(
            argv=tuple(raw["argv"]),
            cwd=raw["cwd"],
            env=tuple(sorted(raw.get("env", {}).items())),
        )


@dataclasses.dataclass(frozen=True)
class Event:
    operation: str
    scope: str
    approval: str
    result: str
    invocation: Invocation
    persistent_prefix: bool = False

    @classmethod
    def from_dict(cls, raw: dict) -> "Event":
        return cls(
            operation=raw["operation"],
            scope=raw["scope"],
            approval=raw["approval"],
            result=raw["result"],
            invocation=Invocation.from_dict(raw["invocation"]),
            persistent_prefix=raw.get("persistent_prefix", False),
        )


def escalation_decision(
    operation: str,
    result: str,
    elevated_attempts: int,
    *,
    tool_supports_escalation: bool = True,
) -> str:
    operation_contract = CONTRACT["operations"].get(operation)
    if result not in DENIAL_RESULTS:
        return "fatal"
    if not operation_contract or not operation_contract["allow_elevated_retry"]:
        return "fatal"
    if not tool_supports_escalation:
        return "fatal"
    if elevated_attempts >= CONTRACT["escalation"]["max_retries_per_operation"]:
        return "fatal"
    return "retry-elevated"


class BaseResolutionReplay:
    def __init__(self) -> None:
        self.state = ReplayState.PR_VIEW
        self.actions: list[str] = []
        self.original_invocations: dict[str, Invocation] = {}
        self.elevated_attempts: dict[str, int] = {}
        self.specialist_spawn_allowed = False

    def fatal(self, reason: str) -> None:
        self.state = ReplayState.FATAL
        self.actions.append(f"fatal:{reason}")
        self.specialist_spawn_allowed = False

    def validate_control_plane(self, event: Event) -> bool:
        if event.persistent_prefix:
            self.fatal("persistent-prefix-forbidden")
            return False
        if event.scope == "sandbox":
            if event.approval != "not-required":
                self.fatal("sandbox-approval-invalid")
                return False
            if event.operation != "pr_view_debug":
                self.original_invocations.setdefault(event.operation, event.invocation)
            return True
        if event.scope != "elevated":
            self.fatal("unknown-execution-scope")
            return False
        if event.approval != "approved":
            self.fatal("escalation-denied-or-unavailable")
            return False
        if event.operation not in CONTRACT["operations"]:
            self.fatal("operation-not-escalatable")
            return False
        attempts = self.elevated_attempts.get(event.operation, 0)
        if attempts >= CONTRACT["escalation"]["max_retries_per_operation"]:
            self.fatal("elevated-retry-limit")
            return False
        original = self.original_invocations.get(event.operation)
        if original is None or original != event.invocation:
            self.fatal("invocation-fingerprint-mismatch")
            return False
        self.elevated_attempts[event.operation] = attempts + 1
        return True

    def process(self, event: Event) -> None:
        if self.state in {ReplayState.CONTINUE, ReplayState.FATAL}:
            self.fatal("event-after-terminal-state")
            return
        if not self.validate_control_plane(event):
            return

        if self.state is ReplayState.PR_VIEW:
            if event.operation != "pr_view" or event.scope != "sandbox":
                self.fatal("expected-sandbox-pr-view")
            elif event.result == "success":
                self.actions.append("validate-pr-metadata")
                self.state = ReplayState.FETCH_BRANCH
            elif event.result in {"malformed-success", "unsafe-branch-success"}:
                self.fatal("invalid-pr-metadata")
            elif event.result == "explicit-no-pr":
                self.fatal("no-pr")
            else:
                self.actions.append("run-pr-view-debug")
                self.state = ReplayState.PR_VIEW_DEBUG
            return

        if self.state is ReplayState.PR_VIEW_DEBUG:
            expected_env = tuple(
                sorted(
                    CONTRACT["operations"]["pr_view"][
                        "debug_discriminator_env"
                    ].items()
                )
            )
            original = self.original_invocations["pr_view"]
            if (
                event.operation != "pr_view_debug"
                or event.scope != "sandbox"
                or event.invocation.argv != original.argv
                or event.invocation.cwd != original.cwd
                or event.invocation.env != expected_env
            ):
                self.fatal("invalid-pr-view-debug-discriminator")
            elif event.result in DENIAL_RESULTS:
                self.actions.append("retry-pr-view-elevated")
                self.state = ReplayState.PR_VIEW_ELEVATED
            elif event.result == "credential-failure-after-response":
                self.fatal("stale-auth")
            elif event.result == "explicit-no-pr":
                self.fatal("no-pr")
            elif event.result == "success":
                self.actions.append("validate-pr-metadata")
                self.state = ReplayState.FETCH_BRANCH
            else:
                self.fatal("ambiguous-pr-view-failure")
            return

        if self.state is ReplayState.PR_VIEW_ELEVATED:
            if event.operation != "pr_view" or event.scope != "elevated":
                self.fatal("expected-elevated-pr-view")
            elif event.result == "success":
                self.actions.append("validate-pr-metadata")
                self.state = ReplayState.FETCH_BRANCH
            elif event.result in {"malformed-success", "unsafe-branch-success"}:
                self.fatal("invalid-pr-metadata")
            elif event.result == "credential-failure-after-response":
                self.fatal("stale-auth")
            elif event.result == "explicit-no-pr":
                self.fatal("no-pr")
            else:
                self.fatal("elevated-pr-view-failed")
            return

        if self.state is ReplayState.FETCH_BRANCH:
            if event.operation != "fetch_branch" or event.scope != "sandbox":
                self.fatal("expected-sandbox-fetch-branch")
            elif event.result == "success":
                self.actions.append("verify-base-oid")
                self.state = ReplayState.VERIFY_OID
            elif (
                escalation_decision(
                    event.operation,
                    event.result,
                    self.elevated_attempts.get(event.operation, 0),
                )
                == "retry-elevated"
            ):
                self.actions.append("retry-fetch-branch-elevated")
                self.state = ReplayState.FETCH_BRANCH_ELEVATED
            else:
                self.fatal("ordinary-fetch-failure")
            return

        if self.state is ReplayState.FETCH_BRANCH_ELEVATED:
            if event.operation != "fetch_branch" or event.scope != "elevated":
                self.fatal("expected-elevated-fetch-branch")
            elif event.result == "success":
                self.actions.append("verify-base-oid")
                self.state = ReplayState.VERIFY_OID
            else:
                self.fatal("elevated-fetch-failed")
            return

        if self.state is ReplayState.VERIFY_OID:
            if event.operation != "verify_oid" or event.scope != "sandbox":
                self.fatal("expected-oid-verification")
            elif event.result != "match":
                self.fatal("base-oid-mismatch")
            else:
                self.actions.append("continue")
                self.state = ReplayState.CONTINUE
                self.specialist_spawn_allowed = True


class BaseResolutionReplayTests(unittest.TestCase):
    def test_sanitized_session_trace_replays_expected_actions(self) -> None:
        fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        replay = BaseResolutionReplay()
        for raw_event in fixture["events"]:
            replay.process(Event.from_dict(raw_event))
        self.assertEqual(replay.actions, fixture["expected_actions"])
        self.assertEqual(
            replay.specialist_spawn_allowed,
            fixture["expected_specialist_spawn_allowed"],
        )

    def test_transport_denial_precedes_credential_text(self) -> None:
        self.assertEqual(
            escalation_decision(
                "pr_view",
                "transport-denial-with-credential-text",
                0,
            ),
            "retry-elevated",
        )

    def test_ordinary_fetch_error_does_not_escalate(self) -> None:
        self.assertEqual(
            escalation_decision("fetch_branch", "ordinary-git-failure", 0),
            "fatal",
        )

    def test_malformed_or_unsafe_pr_metadata_is_fatal_before_spawn(self) -> None:
        argv = tuple(CONTRACT["operations"]["pr_view"]["argv"])
        for result in ("malformed-success", "unsafe-branch-success"):
            with self.subTest(result=result):
                replay = BaseResolutionReplay()
                replay.process(
                    Event(
                        "pr_view",
                        "sandbox",
                        "not-required",
                        result,
                        Invocation(argv, "<repo>", ()),
                    )
                )
                self.assertIs(replay.state, ReplayState.FATAL)
                self.assertFalse(replay.specialist_spawn_allowed)

    def test_each_allowed_operation_retries_at_most_once(self) -> None:
        for operation in CONTRACT["operations"]:
            self.assertEqual(
                escalation_decision(operation, "transport-denial", 0),
                "retry-elevated",
            )
            self.assertEqual(
                escalation_decision(operation, "transport-denial", 1),
                "fatal",
            )

    def test_missing_escalation_tool_field_fails_closed(self) -> None:
        self.assertEqual(
            escalation_decision(
                "pr_view",
                "transport-denial",
                0,
                tool_supports_escalation=False,
            ),
            "fatal",
        )

    def test_immutable_oid_skips_all_external_operations(self) -> None:
        immutable = CONTRACT["immutable_oid"]
        self.assertTrue(immutable["skip_gh"])
        self.assertTrue(immutable["skip_fetch"])
        self.assertTrue(immutable["skip_escalation"])

    def test_elevated_retry_requires_identical_invocation(self) -> None:
        replay = BaseResolutionReplay()
        original = Event(
            operation="pr_view",
            scope="sandbox",
            approval="not-required",
            result="transport-denial",
            invocation=Invocation(("gh", "pr", "view"), "<repo>", ()),
        )
        replay.process(original)
        replay.process(
            Event(
                operation="pr_view_debug",
                scope="sandbox",
                approval="not-required",
                result="transport-denial",
                invocation=Invocation(
                    ("gh", "pr", "view"),
                    "<repo>",
                    (("GH_DEBUG", "api"),),
                ),
            )
        )
        replay.process(
            Event(
                operation="pr_view",
                scope="elevated",
                approval="approved",
                result="success",
                invocation=Invocation(
                    ("gh", "pr", "view", "--repo", "other/repo"),
                    "<repo>",
                    (),
                ),
            )
        )
        self.assertIs(replay.state, ReplayState.FATAL)
        self.assertFalse(replay.specialist_spawn_allowed)

    def test_approval_denial_is_fatal_before_spawn(self) -> None:
        replay = BaseResolutionReplay()
        original_argv = tuple(CONTRACT["operations"]["pr_view"]["argv"])
        replay.process(
            Event(
                "pr_view",
                "sandbox",
                "not-required",
                "transport-denial",
                Invocation(original_argv, "<repo>", ()),
            )
        )
        replay.process(
            Event(
                "pr_view_debug",
                "sandbox",
                "not-required",
                "transport-denial",
                Invocation(original_argv, "<repo>", (("GH_DEBUG", "api"),)),
            )
        )
        replay.process(
            Event(
                "pr_view",
                "elevated",
                "denied",
                "not-run",
                Invocation(original_argv, "<repo>", ()),
            )
        )
        self.assertIs(replay.state, ReplayState.FATAL)
        self.assertFalse(replay.specialist_spawn_allowed)

    def test_oid_mismatch_is_fatal_before_spawn(self) -> None:
        fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        fixture["events"][-1]["result"] = "mismatch"
        replay = BaseResolutionReplay()
        for raw_event in fixture["events"]:
            replay.process(Event.from_dict(raw_event))
        self.assertIs(replay.state, ReplayState.FATAL)
        self.assertFalse(replay.specialist_spawn_allowed)

    def test_persistent_prefix_is_forbidden(self) -> None:
        replay = BaseResolutionReplay()
        replay.process(
            Event(
                "pr_view",
                "sandbox",
                "not-required",
                "transport-denial",
                Invocation(("gh", "pr", "view"), "<repo>", ()),
                persistent_prefix=True,
            )
        )
        self.assertIs(replay.state, ReplayState.FATAL)


if __name__ == "__main__":
    unittest.main(verbosity=2)
    print("OK: pr-review base-resolution contract tests passed")
