# Outer Loop Week 0 v2 Manifest

Schema: `outer-loop-week0/v2`

Execution status: `SUPERSEDED_FOR_FUTURE_EXECUTION`

> **Historical identity only.** This manifest MUST NOT authorize calibration, arming, enrollment, role launch, or real-task execution. [ADR 0032](../../adr/0032-private-lima-outer-loop-calibration-boundary.md) supersedes the zero-build v2 execution path.

Package digest: `sha256:e525d960fcec990b0c61362f0804373f4a37b5672f504fa924ecd8d904f24d06`

Source revision at generation: `outer-loop-week0/v2-content-2-superseded` (informational and excluded from package identity)

Generated on: `2026-07-16` (informational and excluded from package identity)

## Canonical digest input

`manifest.md` excludes itself. Each record is the lowercase SHA-256 of the covered file's exact bytes, two ASCII spaces, its package-root-relative path, and LF. Records are sorted by relative path using C-locale byte order. The package digest is the SHA-256 of the resulting seven records, including each terminal LF.

<!-- BEGIN OUTER_LOOP_WEEK0_V2_MANIFEST_RECORDS -->
```text
85c572fb9ca717c7cada3df71ff61fcdda859978e8c365cd6f9c592721edb893  README.md
839da281e4229960fb532935c3ad559e006b0079c8fb71a12474adc933014365  artifact-templates.md
2c6c10910b550f5ec36f93152d2fbf58c87d0c3cd41b0a355c1aa9fdf0aff063  calibration.md
12ebfe3d8d68c66c9a7a9e9b0accd208624ab3413ade492803ba44baaa540035  claude-invocation.md
d95d81d1d6ad8d0bfba466a2176dbf7187dd4ffcb34503e2f917442a58448cce  codex-invocation.md
e6b8c6e95b1700873675197783e1f34c241f5b2742041c8233b915cb7fcafeed  collector.md
daaffcb9384cf1c533d9205017e1bd37f2c50f9d02c89da4a9a695563f04a070  policy.md
```
<!-- END OUTER_LOOP_WEEK0_V2_MANIFEST_RECORDS -->

## Reproduce on macOS

Run from this directory:

```sh
for file in README.md artifact-templates.md calibration.md claude-invocation.md codex-invocation.md collector.md policy.md; do
  digest=$(shasum -a 256 "$file" | awk '{print $1}')
  printf '%s  %s\n' "$digest" "$file"
done | LC_ALL=C sort -k2,2
```

Hash the exact generated records, including every terminal LF:

```sh
for file in README.md artifact-templates.md calibration.md claude-invocation.md codex-invocation.md collector.md policy.md; do
  digest=$(shasum -a 256 "$file" | awk '{print $1}')
  printf '%s  %s\n' "$digest" "$file"
done | LC_ALL=C sort -k2,2 | shasum -a 256
```

## Reproduce on Linux

Run from this directory:

```sh
LC_ALL=C sha256sum README.md artifact-templates.md calibration.md claude-invocation.md codex-invocation.md collector.md policy.md \
  | LC_ALL=C sort -k2,2
```

Hash the exact generated records:

```sh
LC_ALL=C sha256sum README.md artifact-templates.md calibration.md claude-invocation.md codex-invocation.md collector.md policy.md \
  | LC_ALL=C sort -k2,2 \
  | sha256sum
```

The first field MUST equal `e525d960fcec990b0c61362f0804373f4a37b5672f504fa924ecd8d904f24d06`. This digest identifies the frozen historical package only and MUST NOT authorize any session. The canonical records remain available to verify that archived identity.

Any mismatch means the archived package identity is corrupt and blocks all use and pooling. ADR 0032 used the one permitted pre-observation correction to add supersession notices and regenerate this identity; that correction path is closed. Do not edit v2 in place. Any later proposal must create a new schema/package identity and must not pool with v2.
