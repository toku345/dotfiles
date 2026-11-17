'use strict';
// Manual regression check (not wired into CI): node --test tests/herdr-space-themes.test.cjs
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '../private_dot_config/herdr-app');
const COLORS = ['ansi1', 'ansi2', 'ansi3', 'ansi4', 'ansi5', 'ansi6'];
const TINTED = ['chrome', 'canvas', 'raised'];
const themes = Object.fromEntries(COLORS.map(c => [c, JSON.parse(fs.readFileSync(path.join(root, `themes/space-${c}.json`), 'utf8'))]));
const without = (object, keys) => Object.fromEntries(Object.entries(object).filter(([k]) => !keys.includes(k)));

test('every theme the mod can pick exists, and nothing else', () => {
  const files = fs.readdirSync(path.join(root, 'themes')).filter(f => f.startsWith('space-')).sort();
  assert.deepEqual(files, COLORS.map(c => `space-${c}.json`));
  const mod = fs.readFileSync(path.join(root, 'mods/space-theme/main.js'), 'utf8');
  for (const c of COLORS) assert.match(mod, new RegExp(`"${c}"`));
});

test('themes share one terminal palette and differ only in the tinted surfaces', () => {
  const [first, ...rest] = COLORS.map(c => themes[c]);
  assert.equal(first.ansi.length, 16);
  for (const theme of rest) {
    assert.deepEqual(without(theme, ['colors']), without(first, ['colors']));
    assert.deepEqual(without(theme.colors, TINTED), without(first.colors, TINTED));
  }
  for (const key of TINTED) assert.equal(new Set(COLORS.map(c => themes[c].colors[key])).size, COLORS.length, key);
});

test('all colors are plain hex values', () => {
  for (const theme of Object.values(themes)) {
    for (const value of [theme.background, theme.foreground, theme.selection, theme.cursor, ...theme.ansi, ...Object.values(theme.colors)]) {
      assert.match(value, /^#[0-9a-f]{6}([0-9a-f]{2})?$/);
    }
  }
});
