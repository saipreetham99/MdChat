# MdChat

Native macOS Markdown previewer and vim-keyed editor, with a Gemini chat panel
that answers questions about whatever part of the document you pick — and can
rewrite it in place, behind a diff you approve.

## Requirements

- macOS 13 or newer
- Xcode command line tools, Swift 5.9+ — `xcode-select --install` if `swift
  --version` comes back empty
- An API key for at least one provider: Gemini or Meta Model API (Muse Spark)

No Xcode project and no SwiftPM dependencies. The only third-party code is
vendored JavaScript: markdown-it, Mermaid, and CodeMirror 5 with its vim keymap.

## Setup

```sh
git clone <your-remote> MdChat
cd MdChat
chmod +x fetch-deps.sh build.sh
./fetch-deps.sh          # downloads the pinned JS into Resources/vendor
./build.sh               # -> MdChat.app
open MdChat.app
```

`fetch-deps.sh` needs network access and only has to run once — but it is
required, because `vendor/` is gitignored and the app renders nothing without
it. `build.sh` takes `debug` or `release` (default `release`) and ad-hoc signs
the bundle so Keychain and network access behave.

Move `MdChat.app` wherever you like, or leave it in the tree. Rebuilding
replaces it, so keep it where `build.sh` puts it if you plan to iterate.

## Providers and API keys

Two backends, one conversation. Press **⌘,**, pick the provider tab, paste its
key, set a model ID, **Save**. The checkbox in that sheet is what makes a
provider active — saving a key doesn't switch to it, so you can keep both
configured and flip between them from the toolbar menu or the Chat menu.

| | Gemini | Muse Spark |
| --- | --- | --- |
| Key from | <https://aistudio.google.com/apikey> | Meta Model API (`MODEL_API_KEY`) |
| Endpoint | `streamGenerateContent?alt=sse` | `https://api.meta.ai/v1/chat/completions` |
| Auth header | `x-goog-api-key` | `Authorization: Bearer` |
| Default model | `gemini-3.8-flash` | `muse-spark-1.3-contributor` |

Keys go into your login Keychain under service `MdChat`, one account per
provider — never a file in the project or a plist. Nothing in the repo will ever
contain one. To check or remove them outside the app:

```sh
security find-generic-password -s MdChat -a gemini -w      # print it
security find-generic-password -s MdChat -a museSpark -w
security delete-generic-password -s MdChat -a gemini       # forget it
```

A key stored by an older build under `MdChat.gemini` is migrated to the new
account on first launch.

### Choosing the model ID

The field is free text on purpose — model names change faster than this app
does. For Gemini, ask the API what your key can actually reach:

```sh
curl -s -H "x-goog-api-key: $YOUR_KEY" \
  https://generativelanguage.googleapis.com/v1beta/models \
  | grep '"name"'
```

Pick a Flash-class name from that list, minus the `models/` prefix — a concrete
version rather than a `-latest` alias, so cost tracking can price it. For Muse
Spark, the standard tier is `muse-spark-1.3` and the contributor tier appends
`-contributor` at roughly a tenth the price, in exchange for Meta training on
your prompts. A wrong name surfaces as a plain error in the chat panel rather
than failing silently. Both choices persist in `UserDefaults`.

## First run

1. **⌘O** and pick a `.md` file. The preview live-reloads whenever the file
   changes on disk.
2. Hover a paragraph and click **Ask**, or press **s** and jump to something,
   select with `v`/`V`, and hit **⌘↩**.
3. The chat panel opens with your excerpt attached as a context chip. Type a
   question and press **↩**.

If the panel says to add a key, you skipped ⌘,. If a reply never arrives, check
the model ID first — that's the usual culprit. The toolbar shows which provider
is answering, greyed out when it has no key.

## Shortcuts

| Key | Action |
| --- | --- |
| ⌘O | Open a `.md` file |
| ⌘E | Toggle edit / preview |
| ⌘S | Save (`:w` also works) |
| ⌘J | Toggle chat panel; brings any selection in as context |
| ⌘↩ | Send selection (or the block at the cursor) as context |
| ↩ | Send the chat message (⇧↩ for a newline) |
| ⌘⇧R | Rewrite the selection (ask for an edit) |
| ⌘⌥↩ | Apply the pending rewrite |
| ⌘Z | Undo an applied rewrite (in edit view) |
| ⌘⇧N | New conversation (also stops a stream) |
| ⌘R | Reload from disk, discarding edits |
| ⌘⇧D | Cycle appearance: system, light, dark |
| ⌘, | API keys and models |

## Troubleshooting

**`vendor/ is empty — run ./fetch-deps.sh first`** — exactly what it says. This
guard exists because a build without the JS produces an app that launches to a
blank pane.

**`'someSymbol' is only available in macOS 14.0 or newer`** — you're on macOS
13 and something crept in above the floor. Either replace the symbol or raise
the floor in both `Package.swift` (`.macOS(.v14)`) and `Info.plist`
(`LSMinimumSystemVersion`).

**Preview renders but the editor is blank on ⌘E** — CodeMirror didn't load.
Re-run `./fetch-deps.sh` and confirm ten files are in
`Sources/MdChat/Resources/vendor/`: `markdown-it.min.js`, `mermaid.min.js`,
`codemirror.js`, `codemirror.css`, `cm-xml.js`, `cm-markdown.js`,
`cm-dialog.js`, `cm-dialog.css`, `cm-searchcursor.js`, `cm-vim.js`.

**`/` does nothing in the editor** — `cm-searchcursor.js` is missing; the vim
keymap needs it for search. Re-run `./fetch-deps.sh`.

**Nothing happens on ⌘S** — no file is open, or the app can't write there.
Errors surface in the chat panel in red.

**Vim keys type nothing in the preview** — the web view isn't focused. Click it,
or press ⌘J twice, or Escape out of the chat composer.

## How context selection works

`markdown-it` tokens carry a `map` of source line ranges. A core rule copies
that onto every top-level element as `data-line-start` / `data-line-end`, so the
DOM is a lookup table back into the raw file. Ways to grab context:

- **Hover a block** → the `Ask` button slices those source lines.
- **Hover a heading** → `Whole section` walks forward to the next heading of the
  same or higher rank and slices everything between.
- **Select text** → sends the full lines the selection touches.
- **Vim motions** → move the cursor, select with `v`/`V`, then ⌘↩.
- **⌘J with a selection** → opening the chat carries the selection in.
- **In the editor** → a visual selection, or the paragraph at the cursor.

Every one of these resolves to a line range, not a loose quote, which is what
makes a reply applicable as a patch. A mid-sentence selection therefore sends
the whole lines it touches.

⌘J only takes a real selection. ⌘↩ is the one that falls back to the block at
the cursor when nothing is selected, so opening the panel to ask a plain question
doesn't quietly attach a paragraph you didn't pick.

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
`dd`, registers, macros, `/` and `?` search with `n`/`N`, `:` ex commands. The
mode shows in the same bottom-right badge the preview uses. ⌘↩ sends the visual
selection as context, or the paragraph around the cursor if nothing is selected.

`s` does the same flash-style jump here as in the preview, labelling matches on
the visible lines with `markText` and `addWidget`. Only lowercase `s` is taken,
so vim's `S` still changes a line and `cl` covers what `s` used to do. From
visual mode the jump extends the selection.

The cursor survives the switch. Rendered HTML has the markup stripped, so
there's no direct line/column correspondence to recover — instead both sides are
normalised the same way (markup punctuation dropped, whitespace collapsed, with
an index map back to the original) and matched on a short probe string taken at
the cursor, retried at shrinking lengths. A heading cursor sitting on `Use` in
`## When to **Use** Inheritance` lands past the asterisks, not on them. When no
probe matches, it falls back to the start of the enclosing block.

Both views share one `WKWebView` and one buffer. The preview's own vim layer
stands down whenever the editor is showing, so the two keymaps never both see a
keystroke. Preview re-rendering is skipped while you type and runs on the way
back, which keeps Mermaid off the hot path.

Saving and watching interact carefully: the write is atomic, so it lands as a
rename that the watcher notices, and the reload that follows compares text and
no-ops. If the file changes on disk while your buffer is dirty, the reload backs
off and says so rather than eating your edits — ⌘R forces it.

## Rewriting a section

Select something, press **⌘⇧R**, describe the change ("tighten this", "add a
Florida example", "turn this into a table"), and the reply comes back as a
proposed replacement rather than an answer. The bubble shows a line diff with
**Apply** and **Discard**; ⌘⌥↩ applies the newest pending one. Nothing is
written to the buffer until you decide, and nothing is saved until ⌘S.

Some deliberate choices in there:

**Context is always whole source lines.** Every capture path — block, section,
drag selection, `v`/`V`, editor selection — resolves to a line range, and the
excerpt sent to the model is those exact lines. Partial-line replacement is
where a bad patch corrupts markup, so it isn't possible.

**Patches go through CodeMirror**, creating the editor hidden if you're in
preview. So an applied rewrite is undoable with ⌘Z — but CodeMirror only has the
keyboard in edit view, so ⌘E first, then ⌘Z. The preview re-renders from the
buffer either way.

**A patch is verified before it lands.** The anchor stores the original text
alongside its line range. On apply, if those lines still match, it writes there.
If they don't — you edited above it, or reloaded — it searches the buffer for the
original text and re-anchors if there's exactly one match. Two matches or none
and it refuses and tells you to re-select. That's the whole safety story: an
apply either lands on text identical to what the model saw, or doesn't happen.

**Rewrites don't carry history.** A rewrite request sends only itself, not the
conversation, since prior prose in the context tends to leak into the
replacement. The transcript marker reflects that.

**Streaming patches render as plain monospace** until complete, then become a
diff. Re-parsing markdown per token is fine for a paragraph and visibly slow for
a long section, and a half-arrived diff is noise regardless.

The system prompt for this path lives in `Prompt.rewrite`, separate from the
chat one: raw markdown only, no preamble, preserve heading levels and list
style. `Patch.clean` strips a wrapping fence when the model adds one anyway.

## Cost tracking

Every reply carries a footer: input tokens, output tokens, and what it cost.
Above the composer sits the conversation total, and the settings sheet keeps an
all-time total per provider with a Reset button.

Rates come from a built-in card, checked against both vendors' pricing pages on
the date shown in the ⌘, sheet:

| Model | Input | Output |
| --- | --- | --- |
| `gemini-3.8-flash` / `3.7` / `3.6` | $0.75 | $3.75 |
| `gemini-3.5-flash` | $1.50 | $9.00 |
| `gemini-3.5-flash-lite` | $0.30 | $2.50 |
| `gemini-3.1-flash-lite` | $0.25 | $1.50 |
| `gemini-3.1-pro` | $2.00 | $12.00 |
| `gemini-3-flash` | $0.50 | $3.00 |
| `gemini-2.5-flash` | $0.30 | $2.50 |
| `gemini-2.5-flash-lite` | $0.10 | $0.40 |
| `gemini-2.5-pro` | $1.25 | $10.00 |
| `muse-spark-*-contributor` | $0.10 | $0.20 |
| `muse-spark-*` (standard) | $1.25 | $4.25 |

Matching is longest-prefix, so `gemini-3.5-flash-lite` doesn't get charged
`gemini-3.5-flash` rates, and `gemini-3.1-pro-preview` prices as `3.1-pro`.

You can override any of it: type a rate in the ⌘, sheet and it wins for that
provider-and-model pair; clear the fields to fall back to the card. The sheet
labels which is in effect, with the card's date, so a stale table is visible
rather than silently wrong.

Two caveats the card can't express. Pro-tier rates are the under-200k-context
price — long prompts bill higher. And aliases like `gemini-flash-latest` can't
be priced, since the name doesn't say which model answered; those replies show
token counts and `unpriced model`. Use a concrete model ID if you want costs.

Token counts come from the provider when they're offered. Gemini sends
`usageMetadata` in a trailing SSE frame, and reasoning tokens get folded into
the output count since that's how they bill. Muse Spark needs
`stream_options.include_usage`, which the request now sets, and reports
`prompt_tokens` / `completion_tokens`. If no usage frame arrives — an old API
version, or a stream you stopped early — the count falls back to a chars/4
estimate and is prefixed with `~` so you know it's a guess rather than a
measurement.

Each message stores the provider and model that produced it, so a reply is
priced with the rate that applied when it was sent. Switching provider or
editing a rate never silently reprices your history.

## Two providers, one client

`LLM.swift` is a single SSE reader with two request shapes. Gemini takes a
system prompt as `systemInstruction`, roles named `user`/`model`, and text under
`candidates[].content.parts[]`. Muse Spark is OpenAI-compatible, so the system
prompt is a leading `system` message, `model` maps to `assistant`, and text
arrives at `choices[0].delta.content`. Both frame as `data:` SSE lines, which is
why the read loop, cancellation, and stop button are shared rather than
duplicated.

Everything downstream is provider-agnostic: the same prompts, the same history
budget, the same rewrite-and-diff path. Each reply records which backend produced
it, so switching provider mid-conversation labels bubbles correctly instead of
retroactively renaming old ones — and the transcript continues rather than
resetting, since history is re-serialised per request anyway.

## Replies and history

Replies render as blocks, not one attributed string: `MarkdownText.swift` splits
the text into headings, paragraphs, lists, quotes, rules and fences, then lays
each out natively. Fenced code gets a monospaced block with a language label and
a copy button; inline code gets a monospaced run, which SwiftUI won't do on its
own from `AttributedString`.

Two details matter for streaming. Block ids are positional rather than UUIDs, so
SwiftUI reuses views instead of rebuilding the whole reply on every token. And an
unterminated fence is treated as code through to the end of the text, because
mid-stream that's the normal state — otherwise a code block would render as
prose until its closing fence arrived.

History is budgeted instead of resent whole. Each request walks the transcript
newest-first, keeping entire turns until 24k characters are used, then drops the
rest; the current question always goes regardless of how large its excerpt is.
The window is trimmed to start on a user turn, since the API expects that. When
anything was dropped, a thin `older messages dropped from context` marker appears
in the transcript at the cut, so a model that suddenly can't recall something
earlier is explainable rather than mysterious. Tune `historyBudget` in
`AppState.swift`.

## Layout

```
MdChatApp.swift    @main, window, menu commands
ContentView.swift  HStack split + settings sheet
ChatPanel.swift    transcript, context chip, composer
PreviewView.swift  NSViewRepresentable over WKWebView + JS bridge
AppState.swift     document, file watcher, message list, send()
LLM.swift          streaming client for both providers, no SDK
Provider.swift     provider enum: endpoints, defaults, hints
Pricing.swift      token usage, bundled rate cards, overrides, formatting
Keychain.swift     ~40 lines around SecItem*
Appearance.swift   light/dark/system enum
Prompt.swift       the system prompt, tune it here
MarkdownText.swift block-level renderer for replies
Patch.swift        source anchors, patch verification, line diff
DiffView.swift     the inline diff shown before applying
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
- Only the newest turns that fit a 24k-character budget are sent (see Replies
  and history). Older ones stay in the transcript but leave the model's context.
- Context is line-snapped, so selecting half a sentence sends its whole line.
  Deliberate: partial-line patches are what corrupt markup.
- A rewrite's diff is line-level, so a one-word change shows as a whole line
  replaced. Word-level intra-line diffing isn't implemented.
- The bundled rate card is a snapshot; vendors change prices. Check the date in
  ⌘, and override if it's drifted. Treat totals as an estimate, not a bill.
- Only standard-tier text rates are modelled — not Batch, Flex, Priority,
  context caching, cached-input discounts, or grounding-per-request fees.
- Unsandboxed and ad-hoc signed — it's a local tool. Add entitlements and a real
  signing identity if you want to distribute it.
