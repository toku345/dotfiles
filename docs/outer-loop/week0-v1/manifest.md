# Outer Loop Week 0 v1 Manifest

Schema: `outer-loop-week0/v1`

Package digest: `sha256:be7c2d19627ca8b91583512010f7675ddeefe9c13d53cb5ed9fd41cafffd4b45`

Source revision at generation: `outer-loop-week0/v1-content-9` (informational and excluded from package identity)

Generated on: `2026-07-13` (informational and excluded from package identity)

## Canonical digest input

`manifest.md` excludes itself. Each record is the lowercase SHA-256 of the covered file's exact bytes, two ASCII spaces, its package-root-relative path, and LF. Records are sorted by relative path using C-locale byte order. The package digest is the SHA-256 of the resulting six records, including each terminal LF.

```text
3f9f06372c46d4320829bb28e7fc0e4b80b0f0d388d0b5bb075c3776d37eac76  README.md
3ff7dd85ea73e432b2508f35ad0c376b5c1d131ca968fc07c73289ddd427dae8  artifact-templates.md
ea06a3e992de6cd3e499f2dbb5a4738814634b63e1bf29e9d18033f769d0798f  calibration.md
d206e0d6e6664512a704a9ca2d2b331bbf082890d727614327e22701bd4613da  claude-invocation.md
6a911dd667bdad386d7a13c812498729cb839e2c753a7d7a838fc57f588387b2  codex-invocation.md
225a1ea024e097fa16c87d8756fde277f8d7fe43e1ce08e17d2300c12875f603  policy.md
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
be7c2d19627ca8b91583512010f7675ddeefe9c13d53cb5ed9fd41cafffd4b45
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
