# SimAgentation

Annotate a running iOS simulator in the browser and hand the feedback to a coding agent. It works like [Agentation](https://agentation.com), but for iOS: freeze the screen, click an element or drag a box around anything, and write what should change. The agent gets the element, the screen it is on, strings to search the source for, and two screenshots: the whole screen with the box drawn in red, and a close-up of the box.

Your app needs no SDK. Everything comes from the simulator's accessibility tree, so it works with any app on any booted simulator.

## Requirements

- macOS on Apple Silicon, Xcode 26
- Node and [pnpm](https://pnpm.io), to build the UI

## Run

```sh
pnpm install
pnpm build    # the UI into web/dist, then the Swift binary
pnpm start    # host/.build/debug/sim-agentation serve --open
```

Everything runs in one Swift binary built from `host/`: the web server and API, the MCP server, and the native part that streams the simulator's screen, sends touches, buttons and keys, and reads the accessibility tree through Xcode's private CoreSimulator, SimulatorKit and AccessibilityPlatformTranslation frameworks. It serves the UI from `web/dist` on http://localhost:38470.

The UI is Svelte, in `web/src`. While `pnpm start` runs, `pnpm dev` adds hot reload: the page on http://localhost:38470 then loads the UI from the Vite dev server on 38472, so edits show up without a reload (http://localhost:38472 works too, passing the API and the stream through to the host). The dev server leaves a token for the host to pass the page, and the page loads from it only when they match, so nothing else on that port can. Without `pnpm dev` the page runs `web/dist`; `pnpm build` or `pnpm watch` refreshes it.

The page is laid out like Xcode's Device Hub. On the left, the simulators, with **+** to create one and a filter (all, running, iPhone, iPad). In the middle, the device, drawn with Xcode's own DeviceKit chrome artwork (`/Library/Developer/DeviceKit/Chrome`), so the hardware buttons slide out on hover and press in when clicked; below it, Home, screenshot, screen recording (MP4) and rotate. On the right, an inspector with three tabs: settings, annotations and device info. Selecting a simulator that isn't running shows it with a **Start** button; nothing boots until you press it. The collapse button shows the device alone, and **…** has the rest (copy annotations, lock, app switcher, panels).

- **Interact** (`I`): use the app. Click and drag to touch, scroll with the wheel, type with the keyboard.
- **Annotate** (`⇧⌘D`, in and out): freezes the screen. Hover to see elements, click one to annotate it, or drag a box over any area. Press ⌘↩ to add the note and Esc to go back to the live screen.

The stream picks its codec automatically: H.265, else H.264, else JPEG, taking the first this browser decodes in hardware, and moving on if the host can't encode it or nothing decodes within a few seconds. Both video codecs are encoded by VideoToolbox in hardware with no frame reordering and decoded by WebCodecs in hardware: about 60 fps (the simulator's own rate) at 3–8 Mbit/s while scrolling, against about 85 Mbit/s for JPEG. On Auto, resolution, bitrate and frame rate follow too ([`auto.js`](web/src/lib/auto.js)): full resolution at what the codec needs, unless the window is small, the browser or the Mac can't keep up, or the connection can't carry it. Once a second the host reports how far behind the viewer is and the page how late that report arrived, which also catches a backlog in a tunnel or proxy; when either grows, the bitrate drops to what got through, then half resolution, then 30 fps, and a picture already far behind streams at a trickle until it catches up. While anything is held back, the host pads the stream briefly to see whether the connection has room again, so a connection that recovers is used again within seconds. A hidden tab gets 5 fps. The inspector's settings tab shows what's running and why, and lets you pin a codec, turn on 4:2:2 chroma for H.265 (sharper colored text, about twice the bitrate, no low-latency rate control), halve the resolution or set the bitrate. The pipeline follows [baguette](https://github.com/tddworks/baguette)'s.

Rotating turns the device on the page and sends iOS the orientation change, as Simulator.app does; annotating works turned too, and the screenshots go to the agent upright.

Click **Copy** in the annotations tab to put every pending annotation on the clipboard as Markdown, so you can paste it into any agent without MCP.

## Connect an agent

```sh
claude mcp add sim-agentation -- /path/to/Sim-Agentation/host/.build/debug/sim-agentation mcp
```

The MCP server starts the web server if it isn't running.

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
| `SIM_AGENTATION_WEB` | the repo's `web/` directory (the UI) |
| `SIM_AGENTATION_SDK_URL` | `http://127.0.0.1:38471` |

## Limits

- Without the SDK it doesn't know which source file a view comes from. The agent searches for the labels and identifiers it is given.
- Content without accessibility data, such as custom Canvas or Metal drawing, can only be annotated with a box.
- The native host uses private Simulator frameworks, so a new Xcode release can break it until it's updated.

## Credits

The simulator code in `host/Sources/SimBridge` is adapted from [baguette](https://github.com/tddworks/baguette) by tddworks, under the Apache License 2.0 (`host/Sources/SimBridge/LICENSE-baguette`). Recovering collapsed accessibility children (`CollapsedChildrenRecovery.swift`) is adapted from [sim-use](https://github.com/lycorp-jp/sim-use) by LY Corporation, under the Apache License 2.0 (`host/Sources/SimBridge/LICENSE-sim-use`), and restarting a stale accessibility bridge follows [idb](https://github.com/facebook/idb). Each adapted file notes what changed.
