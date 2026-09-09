#!/bin/sh
# Vendors the JS the preview and editor need. Pinned; run once.
set -eu

DIR="Sources/MdChat/Resources/vendor"
MARKDOWN_IT="14.1.0"
MERMAID="10.9.3"
CODEMIRROR="5.65.16"

mkdir -p "$DIR"

get() {
  curl -fsSL -o "$DIR/$2" "$1"
}

get "https://cdn.jsdelivr.net/npm/markdown-it@${MARKDOWN_IT}/dist/markdown-it.min.js" markdown-it.min.js
get "https://cdn.jsdelivr.net/npm/mermaid@${MERMAID}/dist/mermaid.min.js" mermaid.min.js

# CodeMirror 5 + vim keymap: classic scripts, no bundler needed.
CM="https://cdn.jsdelivr.net/npm/codemirror@${CODEMIRROR}"
get "$CM/lib/codemirror.js" codemirror.js
get "$CM/lib/codemirror.css" codemirror.css
get "$CM/mode/xml/xml.js" cm-xml.js
get "$CM/mode/markdown/markdown.js" cm-markdown.js
get "$CM/addon/dialog/dialog.js" cm-dialog.js
get "$CM/addon/search/searchcursor.js" cm-searchcursor.js
get "$CM/addon/dialog/dialog.css" cm-dialog.css
get "$CM/keymap/vim.js" cm-vim.js

printf 'markdown-it %s, mermaid %s, codemirror %s -> %s\n' \
  "$MARKDOWN_IT" "$MERMAID" "$CODEMIRROR" "$DIR"
