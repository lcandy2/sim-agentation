// iPhone Duo's cover check on automation trees: frames that pass the
// cover's edges on the cover itself don't make a tree the unfolded panel's.
// Run with `pnpm test`.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { withinCover } from '../src/lib/rotation.js';

const cover = { width: 466, height: 678 };
const frame = (x, y, width, height) => ({ x, y, width, height });
const node = (fields, children = []) => ({ hidden: false, ...fields, children });
const app = (children) => node({ role: 'AXApplication', label: 'App', frame: frame(0, 0, 669, 951) }, children);

test('scroll content and full-screen layers past the edges stay on the cover', () => {
  const tree = app([
    // A list's scroll content, above and below the screen.
    node({ role: 'AXGroup', frame: frame(-16, -1580, 498, 2400) }, [
      node({ role: 'AXStaticText', label: 'General', frame: frame(20, 120, 200, 44) }),
    ]),
    // The home screen's next page, beside the screen.
    node({ role: 'AXGroup', frame: frame(466, 0, 466, 678) }),
    // A layer sized and placed in pixels, named or not.
    node({ role: 'AXGroup', label: 'Wallpaper', frame: frame(0, 0, 1398, 2034) }),
  ]);
  assert.equal(withinCover(tree, cover), true);
});

test("a named element past the cover's bottom is the unfolded panel's", () => {
  const tree = app([node({ role: 'AXButton', label: 'Batteries', frame: frame(20, 720, 200, 44) })]);
  assert.equal(withinCover(tree, cover), false);
});

test("a named element past the cover's right edge is the unfolded panel's", () => {
  const tree = app([node({ role: 'AXStaticText', label: 'About', frame: frame(515, 100, 351, 44) })]);
  assert.equal(withinCover(tree, cover), false);
});

test('the root says either size and is not counted', () => {
  assert.equal(withinCover(app([]), cover), true);
});

test("Peri Keys' automation tree fits its own screen", () => {
  const fixtures = new URL('../../host/Tests/Fixtures/', import.meta.url);
  for (const name of ['peri-title-menu.json', 'peri-tabs.json']) {
    const tree = JSON.parse(readFileSync(new URL(name, fixtures)));
    assert.equal(withinCover(tree, { width: 402, height: 874 }), true, name);
  }
});
