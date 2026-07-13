# Outer Loop Week 0 v1 Manifest

Schema: `outer-loop-week0/v1`

Package digest: `sha256:96f90b45cefa6921ede3afb50bb202133722591d27bb316dcbdbac05b6ec8a57`

Source revision at generation: `outer-loop-week0/v1-content-12` (informational and excluded from package identity)

Generated on: `2026-07-13` (informational and excluded from package identity)

## Canonical digest input

`manifest.md` excludes itself. Each record is the lowercase SHA-256 of the covered file's exact bytes, two ASCII spaces, its package-root-relative path, and LF. Records are sorted by relative path using C-locale byte order. The package digest is the SHA-256 of the resulting six records, including each terminal LF.

```text
218e4d7864abc4e9f00d47016136c0f7fafeed3008299d818cffb0f9cef66bb5  README.md
7deb167eb1c8b356d5bb798d42a4931d662625a0cd542270337f94a4d054fc6a  artifact-templates.md
e98e2927415d512bcb78a0f6727baac8c943da2384dac1002defce9f43a6b273  calibration.md
07f6b7c2c3214fda34239fdd51e1749dbbeab2893820857138cd300a70dda859  claude-invocation.md
4ea813c3cad193f82e7aadcf62db655c130334dc07176aa543683e02b9df612d  codex-invocation.md
b7a88bf0903b0f526d3e6806041cc279b5ded5716b77766e8204e78c36604904  policy.md
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
96f90b45cefa6921ede3afb50bb202133722591d27bb316dcbdbac05b6ec8a57
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
