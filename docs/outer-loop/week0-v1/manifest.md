# Outer Loop Week 0 v1 Manifest

Schema: `outer-loop-week0/v1`

Package digest: `sha256:ba491ab31c80c6f0da31a74b7406440025533285b927170b56f3daed23cfdc4c`

Source revision at generation: `outer-loop-week0/v1-content-4` (informational and excluded from package identity)

Generated on: `2026-07-13` (informational and excluded from package identity)

## Canonical digest input

`manifest.md` excludes itself. Each record is the lowercase SHA-256 of the covered file's exact bytes, two ASCII spaces, its package-root-relative path, and LF. Records are sorted by relative path using C-locale byte order. The package digest is the SHA-256 of the resulting six records, including each terminal LF.

```text
41b7ce0cd87796547eb1ea4fd173dfa24b34baf766bcaa5234079f222b253011  README.md
6e679c54b83f1d560462aa525682fb31e8840ab23c1acd9f3e75506e34fee356  artifact-templates.md
6af05fb68c2b874e42363e4bec8f011fe21f7e49852b6a6c05ece18ed0680eae  calibration.md
eeb93694e8f65998abe524956dcfee67e3378b05ce17a9181c6e24731639c4ee  claude-invocation.md
e65a467b541e0acfa000e1ad86cb61a04f7419186bc365ef6f7225f79a988ab4  codex-invocation.md
5495e9f7a0d594dfe276369a646e95a4ac8edb60fc440a571572652c146ccd8a  policy.md
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
ba491ab31c80c6f0da31a74b7406440025533285b927170b56f3daed23cfdc4c
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
