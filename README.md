# sim-agentation

Annotate a running iOS simulator in the browser and hand the feedback to a coding agent. It works like [Agentation](https://agentation.com), but for iOS: freeze the screen, click an element or drag a box around anything, and write what should change. The agent gets the element, the screen it is on, strings to search the source for, and two screenshots: the whole screen with the box drawn in red, and a close-up of the box.

Your app needs no SDK. Everything comes from the simulator's accessibility tree, so it works with any app on any booted simulator.

## Requirements

- macOS on Apple Silicon, Xcode 26
- [Bun](https://bun.sh)

## Run

```sh
(cd host && swift build)
bun src/cli.ts serve --open
```

`host/` is the native part, in Swift: it streams the simulator's screen, sends touches, buttons and keys, and reads the accessibility tree through Xcode's private CoreSimulator, SimulatorKit and AccessibilityPlatformTranslation frameworks. The web server starts it when needed. This opens http://localhost:38470.

The page is laid out like Xcode's Device Hub: simulators on the left, the device in the middle, annotations on the right. Devices are drawn with Xcode's own DeviceKit chrome artwork (`/Library/Developer/DeviceKit/Chrome`), so the hardware buttons slide out on hover and press in when clicked. Selecting a simulator that isn't running shows it with a **Start** button; nothing boots until you press it.

- **Interact** (`I`): use the app. Click and drag to touch, scroll with the wheel, type with the keyboard.
- **Annotate** (`A`): freezes the screen. Hover to see elements, click one to annotate it, or drag a box over any area. Press ⌘↩ to add the note and Esc to go back to the live screen.

Click **Copy** to put every pending annotation on the clipboard as Markdown, so you can paste it into any agent without MCP.

## Connect an agent

```sh
claude mcp add sim-agentation -- bun /path/to/Sim-Agentation/src/cli.ts mcp
```

Tools:

| Tool | What it does |
|---|---|
| `sim_get_pending` | Pending annotations, with element info and screenshot paths |
| `sim_get_all` | All annotations, including finished ones |
| `sim_watch` | Waits until you add an annotation, then returns the pending list |
| `sim_acknowledge` | Marks one as in progress |
| `sim_resolve` | Marks one as fixed, with a summary |
| `sim_dismiss` | Declines one, with the reason |
| `sim_reply` | Posts a message on one |

Status changes and replies show up in the browser sidebar.

## SimAgentationPlus (optional SDK)

Add `sdk/SimAgentationPlus` to an app you build yourself to get exact selections and source locations. Everything compiles out of Release builds.

```swift
import SimAgentationPlus

RootView()
    .simAgentation()      // starts a local inspector on 127.0.0.1:38471 (Debug only)

ShowRow(show: show)
    .simTag()             // selectable as "ShowRow · ContentView.swift:34"
```

UIKit works too, and needs less: every view class your app defines is selectable by name, even without a background, and each annotation names the view controller that owns it. Tag a UIKit view to add its source location:

```swift
let card = TicketCardView(show: show).simTag()   // "TicketCardView · TicketViewController.swift:21"
```

When the app in front has the SDK, the status reads **Frozen · SDK**. Parents then come from the real view and layer tree instead of pixels, so backgrounds that barely differ from the page still work. Each annotation also gets the app's bundle id, a `Source` line with the tagged view's file and line, the owning view controller, and the app-defined view classes around the box. Press `S` or click **SDK** while annotating to compare with the pixel-only fallback.

## Configuration

| Variable | Default |
|---|---|
| `SIM_AGENTATION_PORT` | `38470` |
| `SIM_AGENTATION_HOME` | `~/.sim-agentation` (annotations and screenshots) |
| `SIM_AGENTATION_HOST_URL` | `http://127.0.0.1:38472` (the native host) |
| `SIM_AGENTATION_SDK_URL` | `http://127.0.0.1:38471` |

## Limits

- Without the SDK it doesn't know which source file a view comes from. The agent searches for the labels and identifiers it is given.
- Content without accessibility data, such as custom Canvas or Metal drawing, can only be annotated with a box.
- The native host uses private Simulator frameworks, so a new Xcode release can break it until it's updated.

## Credits

The simulator code in `host/Sources/SimBridge` is adapted from [baguette](https://github.com/tddworks/baguette) by tddworks, under the Apache License 2.0 (`host/Sources/SimBridge/LICENSE-baguette`). Recovering collapsed accessibility children (`CollapsedChildrenRecovery.swift`) is adapted from [sim-use](https://github.com/lycorp-jp/sim-use) by LY Corporation, under the Apache License 2.0 (`host/Sources/SimBridge/LICENSE-sim-use`), and restarting a stale accessibility bridge follows [idb](https://github.com/facebook/idb). Each adapted file notes what changed.
