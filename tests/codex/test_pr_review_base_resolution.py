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
ALLOW_NO_PR_FIXTURE_PATH = (
    REPO_ROOT
    / "tests"
    / "codex"
    / "fixtures"
    / "pr_review_allow_no_pr_base_resolution.json"
)
CONTRACT = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
if CONTRACT.get("sentinel") != "PR_REVIEW_BASE_RESOLUTION_CONTRACT_V2":
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
    FETCH_DEFAULT = "fetch-default"
    FETCH_DEFAULT_ELEVATED = "fetch-default-elevated"
    REMOTE_SET_HEAD = "remote-set-head"
    REMOTE_SET_HEAD_ELEVATED = "remote-set-head-elevated"
    RESOLVE_DEFAULT_HEAD = "resolve-default-head"
    PIN_BASE_COMMIT = "pin-base-commit"
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


def expected_fixed_argv(operation: str) -> tuple[str, ...] | None:
    operation_contract = CONTRACT["operations"].get(operation)
    if not operation_contract or "argv" not in operation_contract:
        return None
    return tuple(operation_contract["argv"])


class BaseResolutionReplay:
    def __init__(self, *, allow_no_pr: bool = False) -> None:
        self.state = (
            ReplayState.FETCH_DEFAULT if allow_no_pr else ReplayState.PR_VIEW
        )
        self.actions: list[str] = []
        self.original_invocations: dict[str, Invocation] = {}
        self.elevated_attempts: dict[str, int] = {}
        self.base_ref: str | None = None
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
            expected_argv = expected_fixed_argv(event.operation)
            if (
                expected_argv is not None
                and event.invocation.argv != expected_argv
            ):
                self.fatal("operation-invocation-mismatch")
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
            return

        if self.state is ReplayState.FETCH_DEFAULT:
            if event.operation != "fetch_default" or event.scope != "sandbox":
                self.fatal("expected-sandbox-fetch-default")
            elif event.result == "success":
                self.actions.append("refresh-remote-head")
                self.state = ReplayState.REMOTE_SET_HEAD
            elif (
                escalation_decision(
                    event.operation,
                    event.result,
                    self.elevated_attempts.get(event.operation, 0),
                )
                == "retry-elevated"
            ):
                self.actions.append("retry-fetch-default-elevated")
                self.state = ReplayState.FETCH_DEFAULT_ELEVATED
            else:
                self.fatal("ordinary-default-fetch-failure")
            return

        if self.state is ReplayState.FETCH_DEFAULT_ELEVATED:
            if event.operation != "fetch_default" or event.scope != "elevated":
                self.fatal("expected-elevated-fetch-default")
            elif event.result == "success":
                self.actions.append("refresh-remote-head")
                self.state = ReplayState.REMOTE_SET_HEAD
            else:
                self.fatal("elevated-default-fetch-failed")
            return

        if self.state is ReplayState.REMOTE_SET_HEAD:
            if event.operation != "remote_set_head" or event.scope != "sandbox":
                self.fatal("expected-sandbox-remote-set-head")
            elif event.result == "success":
                self.actions.append("resolve-default-head")
                self.state = ReplayState.RESOLVE_DEFAULT_HEAD
            elif (
                escalation_decision(
                    event.operation,
                    event.result,
                    self.elevated_attempts.get(event.operation, 0),
                )
                == "retry-elevated"
            ):
                self.actions.append("retry-remote-set-head-elevated")
                self.state = ReplayState.REMOTE_SET_HEAD_ELEVATED
            else:
                self.fatal("ordinary-remote-set-head-failure")
            return

        if self.state is ReplayState.REMOTE_SET_HEAD_ELEVATED:
            if (
                event.operation != "remote_set_head"
                or event.scope != "elevated"
            ):
                self.fatal("expected-elevated-remote-set-head")
            elif event.result == "success":
                self.actions.append("resolve-default-head")
                self.state = ReplayState.RESOLVE_DEFAULT_HEAD
            else:
                self.fatal("elevated-remote-set-head-failed")
            return

        if self.state is ReplayState.RESOLVE_DEFAULT_HEAD:
            path_contract = CONTRACT["paths"]["allow_no_pr"]
            if (
                event.operation != "resolve_default_head"
                or event.scope != "sandbox"
                or event.invocation.argv
                != tuple(path_contract["resolve_default_head_argv"])
            ):
                self.fatal("expected-default-head-resolution")
            elif (
                not event.result.startswith("origin/")
                or event.result == "origin/"
            ):
                self.fatal("invalid-default-head")
            else:
                self.base_ref = event.result
                self.actions.append("pin-base-commit")
                self.state = ReplayState.PIN_BASE_COMMIT
            return

        if self.state is ReplayState.PIN_BASE_COMMIT:
            path_contract = CONTRACT["paths"]["allow_no_pr"]
            expected_argv = tuple(
                f"{self.base_ref}^{{commit}}"
                if value == "<origin-head>^{commit}"
                else value
                for value in path_contract["pin_base_commit_argv_template"]
            )
            if (
                event.operation != "pin_base_commit"
                or event.scope != "sandbox"
                or event.invocation.argv != expected_argv
            ):
                self.fatal("expected-base-commit-pin")
            elif event.result != "commit":
                self.fatal("default-base-does-not-resolve-to-commit")
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

    def test_allow_no_pr_replays_fresh_default_base_and_pins_commit(self) -> None:
        fixture = json.loads(ALLOW_NO_PR_FIXTURE_PATH.read_text(encoding="utf-8"))
        replay = BaseResolutionReplay(allow_no_pr=True)
        for raw_event in fixture["events"]:
            replay.process(Event.from_dict(raw_event))
        self.assertEqual(replay.actions, fixture["expected_actions"])
        self.assertEqual(replay.base_ref, fixture["expected_base_ref"])
        self.assertEqual(
            replay.specialist_spawn_allowed,
            fixture["expected_specialist_spawn_allowed"],
        )

    def test_allow_no_pr_remote_head_retry_preserves_invocation(self) -> None:
        fixture = json.loads(ALLOW_NO_PR_FIXTURE_PATH.read_text(encoding="utf-8"))
        fixture["events"][3]["invocation"]["argv"].append("--mismatch")
        replay = BaseResolutionReplay(allow_no_pr=True)
        for raw_event in fixture["events"]:
            replay.process(Event.from_dict(raw_event))
        self.assertIs(replay.state, ReplayState.FATAL)
        self.assertFalse(replay.specialist_spawn_allowed)

    def test_allow_no_pr_rejects_wrong_initial_operation_argv(self) -> None:
        fixture = json.loads(ALLOW_NO_PR_FIXTURE_PATH.read_text(encoding="utf-8"))
        for sandbox_index, elevated_index in ((0, 1), (2, 3)):
            operation = fixture["events"][sandbox_index]["operation"]
            with self.subTest(operation=operation):
                mutated = json.loads(json.dumps(fixture))
                for event_index in (sandbox_index, elevated_index):
                    mutated["events"][event_index]["invocation"]["argv"] = [
                        "git",
                        "status",
                    ]
                replay = BaseResolutionReplay(allow_no_pr=True)
                for raw_event in mutated["events"]:
                    replay.process(Event.from_dict(raw_event))
                self.assertIs(replay.state, ReplayState.FATAL)
                self.assertIn(
                    "fatal:operation-invocation-mismatch",
                    replay.actions,
                )
                self.assertFalse(replay.specialist_spawn_allowed)

    def test_allow_no_pr_requires_origin_head_and_commit_pin(self) -> None:
        fixture = json.loads(ALLOW_NO_PR_FIXTURE_PATH.read_text(encoding="utf-8"))
        for event_index, result in ((4, "main"), (5, "not-a-commit")):
            with self.subTest(event_index=event_index):
                mutated = json.loads(json.dumps(fixture))
                mutated["events"][event_index]["result"] = result
                replay = BaseResolutionReplay(allow_no_pr=True)
                for raw_event in mutated["events"]:
                    replay.process(Event.from_dict(raw_event))
                self.assertIs(replay.state, ReplayState.FATAL)
                self.assertFalse(replay.specialist_spawn_allowed)

        mismatched_pin = json.loads(json.dumps(fixture))
        mismatched_pin["events"][5]["invocation"]["argv"][-1] = (
            "origin/develop^{commit}"
        )
        replay = BaseResolutionReplay(allow_no_pr=True)
        for raw_event in mismatched_pin["events"]:
            replay.process(Event.from_dict(raw_event))
        self.assertIs(replay.state, ReplayState.FATAL)
        self.assertFalse(replay.specialist_spawn_allowed)

    def test_allow_no_pr_contract_pins_full_transition_sequence(self) -> None:
        self.assertEqual(
            CONTRACT["paths"]["allow_no_pr"]["sequence"],
            [
                "fetch_default",
                "remote_set_head",
                "resolve_default_head",
                "pin_base_commit",
            ],
        )
        self.assertEqual(
            CONTRACT["paths"]["allow_no_pr"]["resolve_default_head_argv"],
            [
                "git",
                "symbolic-ref",
                "--quiet",
                "--short",
                "refs/remotes/origin/HEAD",
            ],
        )
        self.assertEqual(
            CONTRACT["paths"]["allow_no_pr"]["pin_base_commit_argv_template"],
            ["git", "rev-parse", "--verify", "<origin-head>^{commit}"],
        )
        self.assertTrue(
            all(
                CONTRACT["paths"]["allow_no_pr"][key]
                for key in (
                    "require_fresh_default_fetch",
                    "require_remote_head_refresh",
                    "require_origin_head",
                    "require_immutable_base_commit",
                )
            )
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
        original_argv = tuple(CONTRACT["operations"]["pr_view"]["argv"])
        original = Event(
            operation="pr_view",
            scope="sandbox",
            approval="not-required",
            result="transport-denial",
            invocation=Invocation(original_argv, "<repo>", ()),
        )
        replay.process(original)
        replay.process(
            Event(
                operation="pr_view_debug",
                scope="sandbox",
                approval="not-required",
                result="transport-denial",
                invocation=Invocation(
                    original_argv,
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
