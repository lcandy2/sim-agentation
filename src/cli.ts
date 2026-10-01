#!/usr/bin/env bun
import { serve, PORT } from './server';
import { mcp } from './mcp';

const command = process.argv[2] ?? 'serve';

if (command === 'serve') {
  await serve();
  if (process.argv.includes('--open')) Bun.spawn(['open', `http://localhost:${PORT}`]);
} else if (command === 'mcp') {
  await mcp();
} else {
  console.error(`Usage:
  sim-agentation serve [--open]   Start the browser UI on http://localhost:${PORT}
  sim-agentation mcp              Run the MCP server over stdio (for Claude Code, Codex, …)`);
  process.exit(1);
}
