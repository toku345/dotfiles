# Outer Loop Week 0 v1 Manifest

Schema: `outer-loop-week0/v1`

Package digest: `sha256:6b3a1cfe15ea4122447da49cc8a214056a61321852844b3880daf657c0113f53`

Source revision at generation: `outer-loop-week0/v1-content-5` (informational and excluded from package identity)

Generated on: `2026-07-13` (informational and excluded from package identity)

## Canonical digest input

`manifest.md` excludes itself. Each record is the lowercase SHA-256 of the covered file's exact bytes, two ASCII spaces, its package-root-relative path, and LF. Records are sorted by relative path using C-locale byte order. The package digest is the SHA-256 of the resulting six records, including each terminal LF.

```text
5f19fb403e4e44dfb27aeb93ec342773e5c1d6aa8592d0c0ccf6298522176d65  README.md
1844f5ae35305c212bd2746337df17d1b828a41fbc5e5fa8858e7e07085eb108  artifact-templates.md
2df8a35e30494e75a0e66fbbd485759b3420fd1c2213f96ce208a94d3d37cf2c  calibration.md
580ef3a95df98f7793e3f503cd0854e9bda4d15eecd739c5b2e9601ecbc680a0  claude-invocation.md
d79a3b7f58b7c760895ab19ed58b88367cfc5621c01ad31bf7d17c3e8cf39b34  codex-invocation.md
7a95665240178c8c976de891d0f4664519917b7e256b57dd59ebc438dc25da52  policy.md
```

## Reproduce on macOS

Run from this directory:

```sh
for file in README.md artifact-templates.md calibration.md claude-invocation.md codex-invocation.md policy.md; do
  digest=$(shasum -a 256 "$file" | awk '{print $1}')
  printf '%s  %s\n' "$digest" "$file"
done | LC_ALL=C sort -k2,2 | shasum -a 256
```

Expected digest:

```text
6b3a1cfe15ea4122447da49cc8a214056a61321852844b3880daf657c0113f53
```

## Reproduce on Linux

Run from this directory:

```sh
LC_ALL=C sha256sum README.md artifact-templates.md calibration.md claude-invocation.md codex-invocation.md policy.md \
  | LC_ALL=C sort -k2,2 \
  | sha256sum
```

The first field MUST equal the expected package digest. Before a role session, also compare every covered-file digest with the canonical records above; package-digest agreement alone is not a substitute for retaining the manifest evidence locally.

Any mismatch blocks calibration, the affected role session, and cohort pooling. Do not repair an active version in place; follow [policy.md](policy.md#package-identity).
