# Outer Loop Week 0 v1 Manifest

Schema: `outer-loop-week0/v1`

Package digest: `sha256:1fa0b4138d35c9797566e1f27138bd2a893bc5931530309cb7de12774a7e0658`

Source revision at generation: `outer-loop-week0/v1-content-13` (informational and excluded from package identity)

Generated on: `2026-07-13` (informational and excluded from package identity)

## Canonical digest input

`manifest.md` excludes itself. Each record is the lowercase SHA-256 of the covered file's exact bytes, two ASCII spaces, its package-root-relative path, and LF. Records are sorted by relative path using C-locale byte order. The package digest is the SHA-256 of the resulting six records, including each terminal LF.

```text
9370078317930ea01da77af914e94ea28b3bb68cc62b729eee43949d4fb7191b  README.md
ae70b8ac0ba9ced74c072302511bba9f2b034ffb38594666fac5ba524931ac2f  artifact-templates.md
f93ffbdcbaf1f27e57b6319f0516702f45f06729338286703f0941e069a892ce  calibration.md
07f6b7c2c3214fda34239fdd51e1749dbbeab2893820857138cd300a70dda859  claude-invocation.md
4ea813c3cad193f82e7aadcf62db655c130334dc07176aa543683e02b9df612d  codex-invocation.md
c2f3014aafa9ed7338429a0d6a9a8e36cd071f34461c8531afce5afb25d1b46a  policy.md
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
1fa0b4138d35c9797566e1f27138bd2a893bc5931530309cb7de12774a7e0658
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
