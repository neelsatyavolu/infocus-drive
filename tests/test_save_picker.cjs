const { test, afterEach } = require('node:test');
const assert = require('node:assert/strict');

const load = () => import('../app/static/api.js');

const abortAfter = (ms) => () =>
  new Promise((_, reject) => setTimeout(() => reject(new DOMException('The user aborted a request.', 'AbortError')), ms));

afterEach(() => {
  delete globalThis.window;
});

test('a picker the browser rejects at once resolves to null so the download falls back', async () => {
  const { saveFilePicker } = await load();
  globalThis.window = { showSaveFilePicker: abortAfter(0) };
  assert.equal(await saveFilePicker('show.mov'), null);
});

test('a picker the user cancels still rejects as a cancel', async () => {
  const { saveFilePicker, PICKER_INSTANT_ABORT_MS } = await load();
  globalThis.window = { showSaveFilePicker: abortAfter(PICKER_INSTANT_ABORT_MS + 50) };
  await assert.rejects(saveFilePicker('clip.mov'), { name: 'AbortError' });
});

test('a chosen file handle passes through', async () => {
  const { saveFilePicker } = await load();
  const handle = { kind: 'file' };
  globalThis.window = { showSaveFilePicker: async () => handle };
  assert.equal(await saveFilePicker('clip.mov'), handle);
});
