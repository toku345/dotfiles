---
paths:
  - "docs/adr/**"
---

# ADR ドキュメントスタイル

`docs/adr/*.md` の段落は **hard wrap しない** — 段落ごとに 1 logical line (Markdown は viewer の viewport 幅で自動 reflow)。Tables / code blocks / list items / block quotes は通常の multi-line 構造を維持する。新規 ADR はこの style に従う。Legacy ADR (0001 以外) は incremental cleanup 待ちで wrap が残る可能性あり。
