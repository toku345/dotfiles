# Outer Loop Week 0 v2 Manifest

Schema: `outer-loop-week0/v2`

Package digest: `sha256:955b29bdb7eb7a7a9fb9574030b90e099786c97c9a8983ca2820b07390ca12bc`

Source revision at generation: `outer-loop-week0/v2-content-1` (informational and excluded from package identity)

Generated on: `2026-07-15` (informational and excluded from package identity)

## Canonical digest input

`manifest.md` excludes itself. Each record is the lowercase SHA-256 of the covered file's exact bytes, two ASCII spaces, its package-root-relative path, and LF. Records are sorted by relative path using C-locale byte order. The package digest is the SHA-256 of the resulting seven records, including each terminal LF.

<!-- BEGIN OUTER_LOOP_WEEK0_V2_MANIFEST_RECORDS -->
```text
efcde0bfb8daf0db86a2670e4a6e137890003356e9712ac7ae5b29e4a016c78b  README.md
ac0eb88c22bafa15a18b877983947d3f947e52bf950b9bbfc28d9065e6ad1b6f  artifact-templates.md
089a1e77bb1d30963e2aa0c95deb569e0dfd74f02f1cb1a0d3adb104e0fa80c8  calibration.md
73afdc8975203210c666c8d952eef9470ff0a8f55aac45bddbf921f6434b5816  claude-invocation.md
c3f1c3b786a4310d8db16b060b539c848454dc9bb8638fa76514619b5798b365  codex-invocation.md
668b1fc0d4b9b439e39b6626817a14d4eae753bf93853341fea0378b6f3e8f36  collector.md
ead2f0218160e2dfb05005b81ec5fc1b7ec98d68950ff3ad2ded4440bc82e0cf  policy.md
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

The first field MUST equal `955b29bdb7eb7a7a9fb9574030b90e099786c97c9a8983ca2820b07390ca12bc`. Before every role session, also compare each covered-file digest with the canonical records above; aggregate agreement alone is not a substitute for retained local manifest evidence.

Any mismatch blocks calibration, role launch, and cohort pooling. Before the first formal calibration observation, correct covered content only by regenerating every affected record and the aggregate digest and replacing the unobserved package commit. The first formal observation freezes v2. After that point, create a new schema/package instead of editing v2 in place.
