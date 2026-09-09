#!/bin/sh
# Vendors the two JS libraries the preview needs. Pinned; run once.
set -eu

DIR="Sources/MdChat/Resources/vendor"
MARKDOWN_IT="14.1.0"
MERMAID="10.9.3"

mkdir -p "$DIR"

curl -fsSL -o "$DIR/markdown-it.min.js" \
  "https://cdn.jsdelivr.net/npm/markdown-it@${MARKDOWN_IT}/dist/markdown-it.min.js"

curl -fsSL -o "$DIR/mermaid.min.js" \
  "https://cdn.jsdelivr.net/npm/mermaid@${MERMAID}/dist/mermaid.min.js"

printf 'markdown-it %s, mermaid %s -> %s\n' "$MARKDOWN_IT" "$MERMAID" "$DIR"
