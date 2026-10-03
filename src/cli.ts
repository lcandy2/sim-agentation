#!/usr/bin/env bun
import { PORT } from './config';

const command = process.argv[2] ?? 'serve';

// Load only what each command needs: the MCP process must not open the store.
if (command === 'serve') {
  const { serve } = await import('./server');
  await serve();
  if (process.argv.includes('--open')) Bun.spawn(['open', `http://localhost:${PORT}`]);
} else if (command === 'mcp') {
  const { mcp } = await import('./mcp');
  await mcp();
} else {
  console.error(`Usage:
  sim-agentation serve [--open]   Start the browser UI on http://localhost:${PORT}
  sim-agentation mcp              Run the MCP server over stdio (for Claude Code, Codex, …)`);
  process.exit(1);
}
