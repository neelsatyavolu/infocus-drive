const { test } = require('node:test');
const assert = require('node:assert/strict');
const { pathToFileURL } = require('node:url');

// Run: node --test tests/test_app_bundle_kind.cjs
const moduleUrl = pathToFileURL(require('node:path').resolve(__dirname, '../app/static/format.js'));

test('a folder named *.app is a Mac app, not a folder', async () => {
  const { describeKind, isAppBundle } = await import(moduleUrl);
  const app = { name: 'Install DaVinci Graphics.app', path: 'Graphics/Install DaVinci Graphics.app', is_dir: true };
  assert.equal(isAppBundle(app), true);
  assert.equal(describeKind(app).label, 'Mac app');
  assert.equal(describeKind(app).icon, '#i-app');
});

test('plain folders and .app files stay as they were', async () => {
  const { describeKind, isAppBundle } = await import(moduleUrl);
  assert.equal(isAppBundle({ name: 'Shows', is_dir: true }), false);
  assert.equal(describeKind({ name: 'Shows', is_dir: true }).label, 'Folder');
  // A regular file that happens to end in .app is not a bundle.
  assert.equal(isAppBundle({ name: 'notes.app', is_dir: false }), false);
});
