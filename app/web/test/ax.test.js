// What a click picks (hitTest) and what a pick sends the server to name
// its node by (refs), on Peri Keys and Settings on an iPhone 18 Pro
// (402×874 pt). Run with `pnpm test`.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { describe, flatten, hitTest, refs } from '../src/lib/ax.js';

const fixtures = new URL('../../host/Tests/Fixtures/', import.meta.url);
const fixture = (name) => JSON.parse(readFileSync(new URL(`${name}.json`, fixtures)));
const trees = {
  current: fixture('peri-title-menu'),
  old: fixture('peri-tabs'),
  settings: fixture('settings'),
};
const screen = { x: 0, y: 0, width: 402, height: 874 };
const hit = (tree, x, y) => hitTest(trees[tree], x, y).node;

test("the title menu's text names the pop-up", () => {
  const node = hit('current', 190, 75);
  assert.equal(describe(node), 'PopUpButton "Touchpad"');
  assert.equal(node.identifier, 'titleMenu');
});

test('a click on text inside a control keeps the text as its leaf', () => {
  const picked = hitTest(trees.current, 190, 75);
  assert.equal(picked.node.identifier, 'titleMenu');
  assert.equal(describe(picked.leaf.node), 'StaticText "Touchpad"');
  const control = hitTest(trees.current, 38, 84);
  assert.equal(control.leaf.node, control.node);
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

test("the Scroll strip's icon and label name the slider beside them", () => {
  // The current build draws them inside a StaticText with the Slider's frame,
  // next to the Slider; the old build gives the icon the Slider's frame.
  for (const [x, y] of [[358, 440], [358, 459]]) {
    const picked = hitTest(trees.current, x, y, screen);
    assert.equal(describe(picked.node), 'Slider "Scroll"');
    assert.equal(flatten(trees.current)[picked.index].node, picked.node);
    assert.notEqual(picked.leaf.node, picked.node);
  }
  assert.equal(describe(hitTest(trees.current, 358, 440, screen).leaf.node), 'Image "Up And Down Arrows"');
  assert.equal(describe(hit('old', 358, 440)), 'Slider "Scroll"');
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

test("a pick's index is its node's position in the flattened tree", () => {
  const picked = hitTest(trees.current, 190, 75, screen);
  assert.equal(flatten(trees.current)[picked.index].node, picked.node);
  // PickTests.swift resolves this position to the title menu.
  assert.equal(picked.index, 12);
  assert.deepEqual(refs(trees.current, screen, { kind: 'element', rect: picked.node.frame, target: picked.index }), { target: 12 });
});

// Within: what a click at the centre of the box picks, by position.
// BoxNoteTests.swift saves these boxes with the positions checked here.
const within = (tree, rect) => refs(trees[tree], screen, { kind: 'area', rect }).within;
const node = (tree, index) => flatten(trees[tree])[index].node;
const bar = { x: 0, y: 60, width: 402, height: 57 };

test('a box over a bar of tabs is within the tab at its centre', () => {
  assert.equal(within('old', bar), 18);
  assert.equal(describe(node('old', 18)), 'RadioButton "Air Pointer"');
});

test('a box over the title bar is within the title menu', () => {
  assert.equal(within('current', bar), 12);
  assert.equal(node('current', 12).identifier, 'titleMenu');
});

test("a box over Settings' floating search field is within the field", () => {
  assert.equal(within('settings', { x: 20, y: 800, width: 362, height: 44 }), 126);
  assert.equal(node('settings', 126).role, 'AXTextField');
  assert.equal(node('settings', 126).value, 'Search');
});

test('a box over the whole screen is within the element at its centre', () => {
  assert.equal(describe(node('old', within('old', screen))), 'GenericElement "Touchpad"');
});

// The page always sends `within` for a box, null for nothing, so the
// server can tell its notes from an out-of-date page's (PickTests.swift).
test('a box with no tree, or nothing under its centre, is within nothing', () => {
  assert.deepEqual(refs(undefined, screen, { kind: 'area', rect: bar }), { within: null });
  assert.equal(within('old', { x: -100, y: -100, width: 10, height: 10 }), null);
});
