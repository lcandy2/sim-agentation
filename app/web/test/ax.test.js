// The browser's hitTest on the trees the host's tests use
// (app/host/Tests/sim-agentationTests/HitTestTests.swift), so a click names
// the same element on both sides. Run with `pnpm test`.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { describe, hitTest } from '../src/lib/ax.js';

const fixtures = new URL('../../host/Tests/sim-agentationTests/Fixtures/', import.meta.url);
const trees = {
  current: JSON.parse(readFileSync(new URL('peri-current.json', fixtures))),
  old: JSON.parse(readFileSync(new URL('peri-old.json', fixtures))),
};
const hit = (tree, x, y) => hitTest(trees[tree], x, y).node;

test("the title menu's text names the pop-up", () => {
  const node = hit('current', 190, 75);
  assert.equal(describe(node), 'PopUpButton "Touchpad"');
  assert.equal(node.identifier, 'titleMenu');
});

test('the Host icon names the pop-up', () => {
  assert.equal(describe(hit('current', 307, 84)), 'PopUpButton "Host: No Host"');
});

test("a button's icon names the button", () => {
  assert.equal(describe(hit('current', 75, 790)), 'Button "Left click"');
  assert.equal(describe(hit('old', 75, 790)), 'Button "Left click"');
});

test('the Interfaces text names the pop-up', () => {
  const node = hit('old', 340, 126);
  assert.equal(describe(node), 'PopUpButton "Interfaces"');
  assert.equal(node.identifier, 'interfacesMenu');
});

test("a tab's image names the radio button", () => {
  assert.equal(describe(hit('old', 51, 85)), 'RadioButton "Touchpad"');
  assert.equal(describe(hit('old', 240, 85)), 'RadioButton "Game Controller"');
});

test('plain text stays the text', () => {
  const text = 'StaticText "This device can\'t act as a Bluetooth keyboard."';
  assert.equal(describe(hit('current', 200, 125)), text);
  assert.equal(describe(hit('old', 200, 168)), text);
});

test('a named control is its own target', () => {
  assert.equal(describe(hit('current', 38, 84)), 'Button "Settings"');
  assert.equal(describe(hit('current', 358, 300)), 'Slider "Scroll"');
});

test('a widget is one target', () => {
  const frame = (x, y, width, height) => ({ x, y, width, height });
  const tree = {
    role: 'AXApplication', label: '', frame: frame(0, 0, 402, 874), children: [
      { role: 'AXGroup', label: 'Weather', value: 'Widget, Stack', frame: frame(20, 80, 170, 170), children: [
        { role: 'AXStaticText', label: 'Cupertino', frame: frame(36, 96, 90, 20), children: [] },
      ] },
    ],
  };
  assert.equal(describe(hitTest(tree, 50, 100).node), 'Group "Weather"');
});
