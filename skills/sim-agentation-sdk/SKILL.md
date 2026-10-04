---
name: sim-agentation-sdk
description: Add the SimAgentationPlus SDK to an Apple app, so the annotations a user draws in SimAgentation carry the exact Swift file and line of each tagged view, the app's real view tree and its bundle ID. Covers adding the Swift package (Package.swift, XcodeGen, Tuist or a plain .xcodeproj), starting the inspector with .simAgentation(), and choosing where .simTag() goes. Use this whenever the user wants to install, integrate or set up SimAgentationPlus or "the SimAgentation SDK", asks why their annotations have no Source line or how to make selections more precise, mentions .simTag() or .simAgentation(), or wants more views tagged in an app that already has the SDK.
---

# Adding SimAgentationPlus

SimAgentation works on any app from the simulator's accessibility tree, so the SDK is optional. With it, each annotation also names the tagged view and the file and line it comes from, takes parents from the real view and layer tree instead of guessing from pixels, and carries the app's bundle ID. Agents fixing annotations go straight to the code instead of searching for labels.

Everything in the SDK compiles out of Release builds: `.simAgentation()` and `.simTag()` become no-ops, and no `#if DEBUG` is needed around them.

## Facts to work from

| | |
|---|---|
| Package URL | `https://github.com/lcandy2/sim-agentation` |
| Version | from `0.1.1` (up to next major) |
| Package identity | `sim-agentation` |
| Product and module | `SimAgentationPlus` (the package's only library) |
| Platforms | iOS and iPadOS 17, Mac Catalyst 17, macOS 14, tvOS 17, watchOS 10, visionOS 1 |
| Inspector | HTTP on `127.0.0.1:38471`, Debug builds only |

On iOS, iPadOS, Mac Catalyst, tvOS and visionOS the SDK reports views, layers and tags. On macOS and watchOS there are no UIKit views to walk, so it reports `.simTag()` views only.

If a target's deployment target is below these, the package won't link there. Raising a deployment target is the user's decision; say what you found and ask.

## 1. Add the package where the views live

Link the product into the module that contains the SwiftUI or UIKit views you'll tag, and into the app target if that's where the root view is. Find how the project declares dependencies:

- **A local Swift package holds the features** (an `…Package/Package.swift` that the app links, a common layout for Xcode projects with a workspace): edit that `Package.swift`.

  ```swift
  dependencies: [
      .package(url: "https://github.com/lcandy2/sim-agentation", from: "0.1.1"),
  ],
  // in the feature target:
  .target(name: "AppFeature", dependencies: [
      .product(name: "SimAgentationPlus", package: "sim-agentation"),
  ]),
  ```

  Check the package's `platforms` meet the table above.

- **XcodeGen** (`project.yml`): add the package and the target dependency, then run `xcodegen generate`.

  ```yaml
  packages:
    sim-agentation:
      url: https://github.com/lcandy2/sim-agentation
      from: 0.1.1
  targets:
    App:
      dependencies:
        - package: sim-agentation
          product: SimAgentationPlus
  ```

- **Tuist**: add it to `Tuist/Package.swift` and `.external(name: "SimAgentationPlus")` in the target, then `tuist install` and `tuist generate`.

- **A plain `.xcodeproj`** with the views in an app target: run the bundled script. It edits `project.pbxproj` the way Xcode's File > Add Package Dependencies does (package reference, product dependency, Frameworks phase) and leaves the rest of the file untouched. Hand-editing that file is easy to get subtly wrong, which is why the script exists.

  ```sh
  python3 <this skill>/scripts/add_package.py App.xcodeproj --target App
  xcodebuild -resolvePackageDependencies -project App.xcodeproj -scheme App
  ```

  Run it once per target that needs the module. It changes nothing on a second run.

If the app lives inside the SimAgentation repository itself, use a path dependency to the repository root instead of the URL.

## 2. Start the inspector

Call `.simAgentation()` once, on the root view of the app's window, and `import SimAgentationPlus` in that file:

```swift
WindowGroup {
    ContentView()
        .simAgentation()
}
```

Putting it on the root view inside the feature module works too, when that's where the import is. A UIKit app without a SwiftUI root starts it from the app or scene delegate, which run on the main actor:

```swift
SimAgentation.start()
```

The simulator shares the Mac's loopback, so one app at a time can hold port 38471. Two SDK apps in two simulators need different ports: `.simAgentation(port: 38475)`, with the host started with `SIM_AGENTATION_SDK_URL=http://127.0.0.1:38475`.

## 3. Tag the views people will point at

`.simTag()` makes a SwiftUI view selectable under its type name, with the file and line where the call is written. Tag the app's own view types that a designer would click on: rows, cards, sections, custom controls, headers. Annotations on anything inside a tagged view list it as their source, so a few tags at component boundaries cover most of a screen.

Put the tag directly on the custom view, at the place it's used:

```swift
ForEach(items) { item in
    ItemRow(item: item)
        .simTag()          // "ItemRow", at this file and line
}
```

The name comes from the type the modifier is called on. After other modifiers, that type is a wrapper, and the name falls back to `View`:

```swift
ItemRow(item: item).padding().simTag()      // named "View"
ItemRow(item: item).simTag().padding()      // named "ItemRow"
```

Inside a view's own `body`, the type is a stack or other container, so pass the name: `.simTag("ItemRow")`. Tagging system views such as `Text` or `VStack` adds names nobody is looking for; tag the custom type that contains them.

**UIKit** needs less. Every view class the app defines is already selectable by name, and each annotation names the view controller that owns it. Tag an instance to add its file and line; it returns the view, so it chains:

```swift
let card = TicketCardView(ticket: ticket).simTag()
```

A SwiftUI view hosted in UIKit is tagged on the SwiftUI side: `UIHostingController(rootView: PassView(pass: pass).simTag())`.

## 4. Check it

1. Build the scheme for a simulator.
2. Run it, then ask the inspector for its snapshot. The tags you added appear with their names, files and lines:

   ```sh
   curl -s http://127.0.0.1:38471/snapshot | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['bundleId']); [print(t['name'], t['file'], t['line']) for t in d['tags']]"
   ```

   Only tags on screen are listed, so open the screens you tagged.
3. In SimAgentation, the header reads `Frozen · SDK` in Design Mode when the app in front has the SDK, and annotations gain **Source** lines.

If nothing answers on 38471, the inspector didn't start: check that `.simAgentation()` is on a view that appears, that the build is Debug, and that no other app holds the port.

When you're done, tell the user which targets link the SDK, where the inspector starts, and which views you tagged.
