# Outer Loop Week 0 v1 Manifest

Schema: `outer-loop-week0/v1`

Package digest: `sha256:cb887d143c92cf129dd05688a8ea00a747b7a8a336bae007a121cb3b6a2c1daf`

Source revision at generation: `outer-loop-week0/v1-content-11` (informational and excluded from package identity)

Generated on: `2026-07-13` (informational and excluded from package identity)

## Canonical digest input

`manifest.md` excludes itself. Each record is the lowercase SHA-256 of the covered file's exact bytes, two ASCII spaces, its package-root-relative path, and LF. Records are sorted by relative path using C-locale byte order. The package digest is the SHA-256 of the resulting six records, including each terminal LF.

```text
66644556303b1650a019854cb1d90c2b0b1aa816ce8a9b1c856a43cc1f20c343  README.md
1a54df1c370a2d32cfa255c11f7afd43fd2eb82dccd0c31c67166df45c55d4c1  artifact-templates.md
aa5e548613e761432313a6209531748aec63627a0d35a7676a8a6558aa2a7bb2  calibration.md
07f6b7c2c3214fda34239fdd51e1749dbbeab2893820857138cd300a70dda859  claude-invocation.md
4ea813c3cad193f82e7aadcf62db655c130334dc07176aa543683e02b9df612d  codex-invocation.md
15696a585a57946a3998b3b3e0b18e8e31f388f4d322905782165a2a34fe2077  policy.md
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
cb887d143c92cf129dd05688a8ea00a747b7a8a336bae007a121cb3b6a2c1daf
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
