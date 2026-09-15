// Run with: node tests/theme.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../web/theme.js', import.meta.url), 'utf8');
const html = readFileSync(new URL('../web/index.html', import.meta.url), 'utf8');
assert.match(html, /<html[^>]*data-theme="dark"/);
const bootstrap = html.indexOf('<script src="/theme.js"></script>');
assert(bootstrap >= 0 && bootstrap < html.indexOf('<link rel="stylesheet"'));

function load(saved, blocked = false) {
  const meta = { 'meta[name="color-scheme"]': {}, 'meta[name="theme-color"]': {} };
  const context = {
    document: { documentElement: { dataset: {} }, querySelector: selector => meta[selector] },
    matchMedia: query => ({ matches: query.includes('light') }),
    localStorage: {
      getItem: () => { if (blocked) throw new Error('Storage disabled'); return saved; },
      setItem: (key, value) => { if (blocked) throw new Error('Storage disabled'); assert.equal(key, 'gitclub:theme'); saved = value; },
    },
  };
  runInNewContext(source, context);
  return { context, meta, saved: () => saved, theme: () => context.document.documentElement.dataset.theme };
}

for (const saved of [null, 'dark', 'invalid']) assert.equal(load(saved).theme(), 'dark');
assert.equal(load('light').theme(), 'light');
const page = load(null);
page.context.setGitClubTheme('light', true);
assert.equal(page.meta['meta[name="color-scheme"]'].content, 'light');
assert.equal(page.meta['meta[name="theme-color"]'].content, '#fbfcfa');
assert.equal(load(page.saved()).theme(), 'light');
page.context.setGitClubTheme('dark', true);
assert.equal(load(page.saved()).theme(), 'dark');
const blocked = load('light', true);
assert.equal(blocked.theme(), 'dark');
blocked.context.setGitClubTheme('light', true);
assert.equal(blocked.theme(), 'light');
console.log('PASS: dark default, saved choice, reload, browser colors and unavailable storage');
