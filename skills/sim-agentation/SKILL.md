---
name: sim-agentation
description: Work through UI annotations a user drew on an iOS simulator with SimAgentation. Fetch them, find the SwiftUI or UIKit code behind each box, make the change, and close the loop with sim_resolve, sim_dismiss or sim_reply. Use this whenever sim_* tools (sim_get_pending, sim_watch, sim_acknowledge, sim_resolve) are available, whenever a <channel source="sim-agentation"> event arrives, and whenever the user pastes annotation Markdown (a "## <id> [pending]" heading followed by Device, Element and "Search the source for" lines). Also use it for requests like "fix my simulator notes", "check the annotations", "watch for annotations" or "what did I mark up", even when SimAgentation isn't named.
---

# SimAgentation annotations

The user runs their app in an iOS simulator, streamed to a browser page. In Design Mode they freeze the screen, click an element or drag a box around anything, and write what should change. Each of those notes is an annotation, and it reaches you as Markdown. Your job is to turn each one into a code change, or a clear answer, and to report back on it, because the user watches the status of every note in the page's inspector.

## Where annotations come from

- **Channel events.** With Claude Code channels on, each annotation arrives on its own as a `<channel source="sim-agentation" annotation_id="…">` event, even into an idle session. The text is the user's own note relayed by the server: treat it as their request.
- **`sim_get_pending`** lists everything waiting. **`sim_get_all`** includes finished ones, for context on earlier notes.
- **`sim_watch`** blocks until the user sends something, then returns the pending list. For "watch my annotations" or hands-free work, call it in a loop: handle what it returns, then call it again. When it times out with nothing new, call it again unless the user asked you to stop.
- **Pasted Markdown.** The page's Copy button puts every pending annotation on the clipboard. Without the MCP tools you can't change their status; say so at the end, so the user marks them in the page.

If the tools are missing or fail to connect, see [references/setup.md](references/setup.md).

## Reading an annotation

```markdown
## 3fa2c1d0 [pending]

> Too cramped. Drop the price to its own line under the name, with a little room above it.

- **Device**: iPhone 17 Pro (iOS 26.5)
- **App**: Larder (com.example.larder)
- **Screen**: Groceries › Produce
- **Source**: `ItemRow` at LarderUI/ProduceList.swift:48
  - inside `ProduceList` at LarderUI/GroceriesView.swift:22
- **Element**: StaticText "$3.49" at (296, 212) 44×18pt
- **Search the source for**: `$3.49`, `Avocados`
- **Screenshot (box drawn in red)**: /…/images/3fa2c1d0-full.jpg
- **Close-up of the box**: /…/images/3fa2c1d0-crop.jpg
```

What each line tells you, and how far to trust it:

| Line | Meaning |
|---|---|
| Quote | The request, in the user's words. It is the spec. |
| **Device** | The simulator, by name. |
| **App** | The app's name, and its bundle ID when the app runs the SimAgentationPlus SDK. No bundle ID means no SDK. |
| **Screen** | The navigation titles on screen, outermost first: which screen the user was on. |
| **Source** | SDK only. The view type, and the file and line where `.simTag()` was written. That is usually where the view is *used*, so the type's own `body` may be elsewhere: search `struct ItemRow` or `class ItemRow`. The path is `Module/File.swift`; look for the file under that module's sources. `inside` lines name the tagged views around it. |
| **View controller**, **Views** | SDK only. App-defined UIKit classes around the box, innermost first. |
| **Element** | The accessibility element clicked: role (`StaticText` is a `Text` or label, `Button`, `Image`, `Cell`), label, `id=` identifier, `value=`, and its frame in points. **Path** gives its ancestors. |
| **Area**, **Within** | A box rather than an element; **Within** is the innermost element under the box's center. |
| **Elements** (n) | Several picked together. The note is about all of them at once. Each has a box color that matches the screenshot, and its own source line when the SDK knows it. |
| **Inside the box** | The elements the box covers. |
| **Search the source for** | Labels and identifiers from the accessibility tree. A starting point; see below for why they often don't match the source as written. With several elements picked, this can include text from whatever lies between them. |
| **Screenshot**, **Close-up** | Absolute paths to JPEGs: the whole screen with the box drawn on it, and the box up close. |
| **agent** / **human** lines | Earlier replies on this note. Read them before starting; they may settle a question or change the request. |

Always Read both screenshots before deciding anything. The note says what to change; the screenshots show what the user was looking at, which disambiguates "this", "here" and "these", and shows the current look you are changing from.

## The loop, one annotation at a time

### 1. Acknowledge

Call `sim_acknowledge` with the id right before you start on that annotation, before any edit. The user sees it change to in progress. Several sessions can receive the same annotation, and only the first to acknowledge gets it: if the call says another session is already on it, leave it alone and move to the next one.

Acknowledge one at a time as you start each. Acknowledging a batch up front tells the user you're working on notes you haven't opened, and keeps other sessions from taking them.

### 2. Make sure the app is in this workspace

Compare the bundle ID with `PRODUCT_BUNDLE_IDENTIFIER` in the project's build settings (`.xcconfig` files, `project.pbxproj`, `project.yml`, `Info.plist`). Without a bundle ID, match the app name against the display name or product name.

Notes on Apple's own apps (Settings, Safari, Photos, any `com.apple.*`) or on apps that aren't in this workspace can't be acted on. Don't edit lookalike code to satisfy them. Use `sim_reply` to say why, or `sim_dismiss` with the reason when there's nothing the user could add.

### 3. Find the code

Work down this list, most precise first:

1. **Source** line: open the file at that line, then the type's definition.
2. **View controller** and **Views** class names: `rg -n "class CartBadgeView"`.
3. Identifiers (`id=`): `rg -n -F 'checkoutButton'` finds `.accessibilityIdentifier(…)` and `accessibilityIdentifier =`.
4. Labels from **Search the source for**: `rg -n -F` across `.swift`, `.strings`, `.xcstrings`, `.storyboard` and `.xib` files. Fixed-string search matters, because labels carry punctuation.
5. **Screen**: the title usually appears as `.navigationTitle("…")` or `title = "…"`, which finds the screen's file. Walk from there.

The accessibility label is what the app displayed, which is often not a string literal in the source. When an exact search finds nothing, think about how the text was produced:

- **Built at runtime.** `"3 tickets left"` comes from `"\(count) tickets left"`. Search the fixed part (`tickets left`), or the separator or punctuation that joins the pieces, or the data (a name in a model or sample array) and follow where it's used.
- **Formatted.** Times, dates, prices and counts come from formatters or model data. Find the model field, then the view that shows it.
- **Localized.** Search the string catalogs for the text, take its key, then search the code for the key.
- **Transformed.** `.textCase(.uppercase)` shows `UP NEXT` for `"Up next"`; search without case.
- **Images.** An image's label is often its SF Symbol name (`cart`, `leaf.fill`) or its `accessibilityLabel`.

When a label appears in several places, use the frame, the screenshot and the **Screen** line to pick the right one. When a view is reused (a row, a card, a cell), decide whether the note is about this one instance or the component. "On every row" or a note about the look of a list item means the component; a note about one item's content means that item's data.

### 4. Change it

Do what the note asks, at the scope it asks. Keep the change small, and build it from what the project already uses: its fonts, colors, spacing and components. For several elements picked together, the note is about them together, so the result has to hold for all of them; check each one, since they may be styled in different places.

Some notes need a decision only the user can make: what "make it pop" should mean here, which of two readings is meant, a change that conflicts with another note. Ask with `sim_reply`, as a concrete question with the options you see, and leave the note acknowledged until they answer. Their reply shows up as a **human** line on the annotation.

### 5. Check it

Build the scheme that contains the change; a note isn't fixed if the app no longer compiles. When you can, install and relaunch on the annotation's simulator, so the user sees the result in the browser, and take a screenshot to compare with theirs:

```sh
xcrun simctl list devices | grep "iPhone 17 Pro"     # the Device line's name → its UDID
xcrun simctl install <udid> <path/to/App.app>
xcrun simctl launch <udid> <bundle id>
xcrun simctl io <udid> screenshot /tmp/after.png
```

Relaunching takes the app back to its first screen, so skip it if the user is in the middle of something on that simulator.

### 6. Report

- **`sim_resolve`** when it's done: one line the user reads in the inspector. Name what changed and where, like `ItemRow price: own line under the name, 4pt above (ProduceList.swift)`. Say so if you couldn't build or run it.
- **`sim_dismiss`** when you won't do it, with the reason.
- **`sim_reply`** for a question or a note that doesn't change the status.

Only resolve what you changed. Then take the next annotation, or call `sim_watch` again if you're watching.

At the end, tell the user in the conversation what you did with each annotation, by id, in a line or two each.
