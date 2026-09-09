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
package dependencies — just SwiftPM and two vendored JS files.

First run: press ⌘, and paste your Gemini API key. It goes into the login
Keychain, not a plist. The model ID is a free text field, so set it to whatever
string the API currently expects for the Flash model you want.

## Shortcuts

| Key | Action |
| --- | --- |
| ⌘O | Open a `.md` file |
| ⌘J | Toggle chat panel |
| ⌘⇧C | Send current selection (or hovered block) as context |
| ⌘↩ | Send the message |
| ⌘⇧N | New conversation |
| ⌘R | Reload from disk |
| ⌘, | API key and model |

## How context selection works

`markdown-it` tokens carry a `map` of source line ranges. A core rule copies
that onto every top-level element as `data-line-start` / `data-line-end`, so the
DOM is a lookup table back into the raw file. Three ways to grab context:

- **Hover a block** → the `Ask` button slices those source lines.
- **Hover a heading** → `Whole section` walks forward to the next heading of the
  same or higher rank and slices everything between.
- **Select text** → sends the selection verbatim.

Because slices come from the source rather than `textContent`, code blocks and
Mermaid diagrams arrive as their original fenced source, which is what the model
actually wants to reason about.

## Layout

```
MdChatApp.swift    @main, window, menu commands
ContentView.swift  HStack split + settings sheet
ChatPanel.swift    transcript, context chip, composer
PreviewView.swift  NSViewRepresentable over WKWebView + JS bridge
AppState.swift     document, file watcher, message list, send()
Gemini.swift       generateContent POST, no SDK
Keychain.swift     ~40 lines around SecItem*
Resources/preview.html  render + line mapping + context pickers
```

Live reload uses a `DispatchSourceFileSystemObject` on the file descriptor and
re-arms itself on `.rename`/`.delete`, since most editors save by writing a temp
file and renaming over the original. Scroll position is preserved across
re-renders.

## Known limits

- Replies aren't streamed; the panel shows a spinner until the full response
  lands.
- Model replies render with `AttributedString(markdown:)`, which handles inline
  formatting but not fenced code blocks in the reply.
- The whole conversation is resent each turn. Fine for a document Q&A session;
  ⌘⇧N when it gets long.
- Unsandboxed and ad-hoc signed — it's a local tool. Add entitlements and a real
  signing identity if you want to distribute it.
