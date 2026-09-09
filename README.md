# MdChat

Native macOS Markdown previewer with a Gemini chat panel that answers questions
about whatever part of the document you pick.

## Build

```sh
chmod +x fetch-deps.sh build.sh
./fetch-deps.sh      # vendors markdown-it + mermaid (pinned, once)
./build.sh           # -> MdChat.app
open MdChat.app
```

Needs Xcode command line tools (Swift 5.9+) and macOS 13+. No Xcode project, no
SwiftPM dependencies — just vendored JS: markdown-it, Mermaid, and CodeMirror 5
with its vim keymap.

First run: press ⌘, and paste your Gemini API key. It goes into the login
Keychain, not a plist. The model ID is a free text field, so set it to whatever
string the API currently expects for the Flash model you want.

## Shortcuts

| Key | Action |
| --- | --- |
| ⌘O | Open a `.md` file |
| ⌘E | Toggle edit / preview |
| ⌘S | Save (`:w` also works) |
| ⌘J | Toggle chat panel |
| ⌘↩ | Send selection (or the block at the cursor) as context |
| ↩ | Send the chat message (⇧↩ for a newline) |
| ⌘⇧N | New conversation (also stops a stream) |
| ⌘R | Reload from disk, discarding edits |
| ⌘⇧D | Cycle appearance: system, light, dark |
| ⌘, | API key and model |

## How context selection works

`markdown-it` tokens carry a `map` of source line ranges. A core rule copies
that onto every top-level element as `data-line-start` / `data-line-end`, so the
DOM is a lookup table back into the raw file. Three ways to grab context:

- **Hover a block** → the `Ask` button slices those source lines.
- **Hover a heading** → `Whole section` walks forward to the next heading of the
  same or higher rank and slices everything between.
- **Select text** → sends the selection verbatim.
- **Vim motions** → move the cursor, select with `v`/`V`, then ⌘↩.

Because slices come from the source rather than `textContent`, code blocks and
Mermaid diagrams arrive as their original fenced source, which is what the model
actually wants to reason about.

## Vim motions in the preview

Click the preview (or press ⌘J to hide the chat) to give it the keyboard.

| Keys | |
| --- | --- |
| `h` `j` `k` `l` | character and line movement |
| `w` `b` `e` | word movement |
| `0` `^` `$` | line start and end |
| `{` `}` | paragraph |
| `gg` `G` | top and bottom |
| `v` `V` | charwise and linewise visual; press again or Escape to leave |
| `s` | flash-style jump: type a couple of characters, press the label |
| `/` then Enter | search; `n` and `N` walk the matches |
| ⌘↩ | send the visual selection, or the block under the cursor |
| Escape | leave visual mode, clear the search |

A mode badge sits bottom-right when visual mode or a search is active. Lowercase
searches are case-insensitive, mixed-case ones aren't, the way `smartcase` works.

`s` labels only what's on screen, so the label set stays short. Labels are
assigned nearest-to-cursor first, and any character that could be the next one
you type is dropped from the label pool — so typing keeps refining and a label
press always means jump. One remaining match jumps on its own. Backspace steps
back a character, Escape cancels. In visual mode the jump extends the selection
instead of moving the cursor, which pairs with ⌘↩ for grabbing an odd-shaped
range.

Movement leans on WebKit's `Selection.modify`, which supplies real word and line
granularity, so `j` follows wrapped visual lines rather than source lines — same
as vim without `gj`. Two consequences worth knowing: `e` behaves like `w` because
WebKit has no word-end granularity, and count prefixes (`3j`) aren't wired up.
Clicking moves the cursor too, so mouse and keyboard stay in agreement.

## Editing

⌘E switches between preview and editor; the toolbar shows a pencil or an eye,
and a dot appears next to the filename when the buffer is dirty. ⌘S writes the
file, and `:w`, `:wq`, and `:prev` are wired to the same path.

The editor is CodeMirror 5 with its `keymap/vim`, so you get the real thing:
insert, replace, visual and visual-line modes, counts, text objects (`ciw`),
`dd`, registers, macros, `/` search with the dialog addon. The mode shows in the
same bottom-right badge the preview uses. ⌘↩ sends the visual selection as
context, or the paragraph around the cursor if nothing is selected.

Both views share one `WKWebView` and one buffer. The preview's own vim layer
stands down whenever the editor is showing, so the two keymaps never both see a
keystroke. Preview re-rendering is skipped while you type and runs on the way
back, which keeps Mermaid off the hot path.

Saving and watching interact carefully: the write is atomic, so it lands as a
rename that the watcher notices, and the reload that follows compares text and
no-ops. If the file changes on disk while your buffer is dirty, the reload backs
off and says so rather than eating your edits — ⌘R forces it.

## Layout

```
MdChatApp.swift    @main, window, menu commands
ContentView.swift  HStack split + settings sheet
ChatPanel.swift    transcript, context chip, composer
PreviewView.swift  NSViewRepresentable over WKWebView + JS bridge
AppState.swift     document, file watcher, message list, send()
Gemini.swift       streamGenerateContent SSE, no SDK
Keychain.swift     ~40 lines around SecItem*
Appearance.swift   light/dark/system enum
Prompt.swift       the system prompt, tune it here
Resources/preview.html  render + line mapping + pickers + vim layer + editor
```

Appearance is set on `NSApplication.shared`, which covers the SwiftUI chrome and
the preview together: WebKit maps the view's effective appearance onto
`prefers-color-scheme`, so the CSS variables and the Mermaid theme both follow.
The preview listens for the change and re-renders, since Mermaid bakes its theme
into the generated SVG.

Live reload uses a `DispatchSourceFileSystemObject` on the file descriptor and
re-arms itself on `.rename`/`.delete`, since most editors save by writing a temp
file and renaming over the original. Scroll position is preserved across
re-renders.

## Known limits

- Replies stream over SSE. The send button becomes a stop button while tokens
  are arriving; stopping keeps whatever text already landed.
- Model replies render with `AttributedString(markdown:)`, which handles inline
  formatting but not fenced code blocks in the reply.
- The whole conversation is resent each turn. Fine for a document Q&A session;
  ⌘⇧N when it gets long.
- Unsandboxed and ad-hoc signed — it's a local tool. Add entitlements and a real
  signing identity if you want to distribute it.
