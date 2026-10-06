# Setting up SimAgentation

> [!TIP]
> This page is written for an AI coding agent. Paste this into Claude Code, Codex, Cursor or any other agent, and it does the rest:
>
> ```
> Set up SimAgentation for me by following https://github.com/lcandy2/sim-agentation/raw/refs/heads/main/SETUP.md
> ```

You're setting up SimAgentation for the user. It streams their iOS simulator to the browser, where they click elements or draw boxes and write what should change; each note reaches you through an MCP server, with screenshots and strings to search the source for. Work through the steps in order.

Before you run anything that installs software or changes the user's agent configuration, say what you're about to run and wait for their go-ahead.

## Read these first

Once it's set up, you're the one the user's notes go to, so read how SimAgentation works before installing it. Fetch these the way you fetched this page:

- [README.md](https://github.com/lcandy2/sim-agentation/raw/refs/heads/main/README.md): what SimAgentation does, the ways to install it, and how the user annotates.
- [skills/sim-agentation/SKILL.md](https://github.com/lcandy2/sim-agentation/raw/refs/heads/main/skills/sim-agentation/SKILL.md): how you'll work through the user's annotations, from reading one and finding its code to resolving it.
- [skills/sim-agentation-sdk/SKILL.md](https://github.com/lcandy2/sim-agentation/raw/refs/heads/main/skills/sim-agentation-sdk/SKILL.md): adding the SimAgentationPlus SDK to an app, for step 4.

## 1. Check the Mac

Run these and read the results:

```sh
uname -m                                    # arm64: Apple Silicon
xcodebuild -version                         # Xcode 26 or later
xcrun simctl list devices available | head  # at least one iOS simulator
```

- An Intel Mac (`x86_64`) isn't supported. Stop and tell the user.
- Without Xcode 26 or later, the user installs it from the App Store or developer.apple.com, then opens it once to finish installing its components. You can't do this for them. iPhone Duo needs Xcode 27.1.
- With no simulators listed, Xcode's iOS platform is missing: the user adds it in Xcode, under Settings > Components.

## 2. Install it for the agent you're running in

Use the section for your own agent. The plugin brings the MCP server, two skills (one for working through annotations, one for adding the SDK to an app), and SimAgentation itself: the first time the server starts, it downloads the matching release (about 2 MB) into `~/Library/Caches/sim-agentation`.

### Claude Code

```sh
claude plugin marketplace add lcandy2/sim-agentation
claude plugin install sim-agentation@sim-agentation
```

The plugin's tools load with the next session: ask the user to start a new one.

### Codex

```sh
codex plugin marketplace add https://github.com/lcandy2/sim-agentation.git
codex plugin add sim-agentation@sim-agentation
```

The plugin's tools load with the next session: ask the user to start a new one.

### Cursor

Cursor adds plugins from its own interface: point the user to [Cursor's guide](https://cursor.com/docs/plugins#installing-plugins) with this repository, `https://github.com/lcandy2/sim-agentation`. If they'd rather you set it up, install the parts yourself:

```sh
brew install lcandy2/tap/sim-agentation
npx skills add lcandy2/sim-agentation -a cursor -y
```

Then add the server to `~/.cursor/mcp.json`, merging it into what's there rather than replacing the file:

```json
{
  "mcpServers": {
    "sim-agentation": { "command": "sim-agentation", "args": ["mcp"] }
  }
}
```

### Any other agent

```sh
brew install lcandy2/tap/sim-agentation
npx skills add lcandy2/sim-agentation -a <agent> -y
```

`-a` names the agent to install the skills for, as the [skills CLI](https://github.com/vercel-labs/skills#supported-agents) spells it, and `-y` skips its questions, which you can't answer from a script. Then add a stdio MCP server to your client's configuration, named `sim-agentation`, that runs `sim-agentation` with the argument `mcp`.

Without Homebrew (`brew` not found), point the user to https://brew.sh rather than installing it yourself, or use the Claude Code or Codex plugin, which needs no Homebrew.

## 3. Check that it works

- With Homebrew: `sim-agentation version` prints the version.
- In the new session: the `sim_*` tools are there, and `sim_get_pending` answers "No pending annotations."
- The MCP server starts the page on http://localhost:38470 when it isn't running; `sim-agentation serve --open` starts it and opens the browser. The user picks a simulator on the left and presses **Start** if it isn't running.

If a step fails, [skills/sim-agentation/references/setup.md](https://github.com/lcandy2/sim-agentation/raw/refs/heads/main/skills/sim-agentation/references/setup.md) lists what each error means.

## 4. Optional: exact source locations

If the user builds their own iOS app and it's in your workspace, annotations can carry the Swift file and line of each tagged view. The `sim-agentation-sdk` skill, which you read above, adds the SimAgentationPlus SDK to their project. It edits the project, so offer it and let the user decide.

## 5. Tell the user how to use it

Keep it to a few lines:

1. Open http://localhost:38470 and pick a simulator.
2. Press ⇧⌘D for Design Mode. Click an element or drag a box, write what should change, and press ⌘↩.
3. Ask you to "go through my simulator annotations", or to "watch for my annotations" and fix them as they arrive.

For everything else, point them to the [README](https://github.com/lcandy2/sim-agentation#readme).
