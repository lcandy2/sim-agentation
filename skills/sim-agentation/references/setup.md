# Setup and troubleshooting

## Connecting the tools

The MCP server is the `sim-agentation` binary, run with `mcp`. It speaks stdio and starts the web server on port 38470 if it isn't running. Homebrew installs it (`brew install lcandy2/tap/sim-agentation`), and the SimAgentation plugin for Claude Code or Codex configures the server. Without the plugin:

```sh
claude mcp add sim-agentation -- sim-agentation mcp
codex mcp add sim-agentation -- sim-agentation mcp
```

A source build's binary is `app/host/.build/debug/sim-agentation` in the SimAgentation repository.

To have each annotation arrive in a Claude Code session as the user sends it, the session is started or resumed with the server as a channel:

```sh
claude --dangerously-load-development-channels server:sim-agentation
claude --resume <session> --dangerously-load-development-channels server:sim-agentation
```

Without the flag, nothing is pushed and the tools work as before: use `sim_watch` to wait for annotations.

Adding an MCP server changes the user's configuration, so suggest the command and let the user run it.

## When something fails

| Symptom | What it means |
|---|---|
| No `sim_*` tools | The MCP server isn't configured for this client, or failed to start. The plugin's server says "sim-agentation is not installed" when Homebrew hasn't installed it. |
| "Unable to connect" | The web server isn't up and couldn't be started. The user can run `pnpm start` in the SimAgentation repository and open http://localhost:38470. |
| "another agent session is already working on this annotation" | Another session acknowledged it first. Leave it. |
| `sim_watch` returns "Nothing new yet" | It timed out (about 100 seconds). Call it again to keep waiting. |
| An annotation has no **Source** line | The app doesn't run the SimAgentationPlus SDK. Search by labels; if the user wants exact source lines, the `sim-agentation-sdk` skill adds the SDK. |

## Without MCP

The web server has the same data over HTTP, on `http://localhost:38470` unless `SIM_AGENTATION_PORT` says otherwise:

```sh
curl -s 'http://localhost:38470/api/annotations?status=pending'      # JSON list
curl -s  http://localhost:38470/api/annotations/<id>                 # one, with a "markdown" field
curl -s -X PATCH http://localhost:38470/api/annotations/<id> \
  -H 'Content-Type: application/json' \
  -d '{"status":"acknowledged","by":"<a name for this session>"}'
curl -s -X PATCH http://localhost:38470/api/annotations/<id> \
  -H 'Content-Type: application/json' \
  -d '{"status":"resolved","resolution":"<one-line summary>"}'      # or "dismissed", with the reason
curl -s -X PATCH http://localhost:38470/api/annotations/<id> \
  -H 'Content-Type: application/json' \
  -d '{"reply":{"from":"agent","message":"<question>"}}'
```
