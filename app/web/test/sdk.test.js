// The SDK's Source line for a click: the control the click names, with a
// tag on the text inside it. Run with `pnpm test`.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { sourceFor } from '../src/lib/sdk.js';

const frame = (x, y, width, height) => ({ x, y, width, height });
const sdk = {
  tags: [
    { name: 'TopBar', file: 'App/TopBar.swift', line: 12, frame: frame(0, 62, 402, 54) },
    { name: 'TitleMenu', file: 'App/TitleMenu.swift', line: 30, frame: frame(139, 66, 134, 36) },
    { name: 'ModeTitle', file: 'App/TitleMenu.swift', line: 41, frame: frame(170, 68, 79, 20) },
  ],
};
const names = (tags) => tags.map((t) => t.name);

test("a click's leaf brings in the tag inside the control, innermost first", () => {
  const control = frame(139, 66, 134, 36);
  assert.deepEqual(names(sourceFor(sdk, control)), ['TitleMenu', 'TopBar']);
  assert.deepEqual(names(sourceFor(sdk, control, frame(172, 70, 75, 16))), ['ModeTitle', 'TitleMenu', 'TopBar']);
});

test('a box has no leaf: only the tags around it count', () => {
  assert.deepEqual(names(sourceFor(sdk, frame(0, 62, 402, 54))), ['TopBar']);
});
