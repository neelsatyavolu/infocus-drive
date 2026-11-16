const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const vm = require('node:vm');

const source = readFileSync(`${__dirname}/../app/static/editing-upload.js`, 'utf8');
const fn = source.match(/^export function chunkSizeFor\([^]*?^}/m)[0].replace('export ', '');
const MiB = 1024 * 1024;
const context = vm.createContext({ MIB: MiB, STREAMS: 4, MAX_CHUNK: 32 * MiB, BASE_CHUNK: 8 * MiB, MAX_CHUNKS: 256 });
vm.runInContext(fn, context);

test('footage uploads use 8 MiB chunks so a dropped upload resumes close to where it stopped', () => {
  assert.equal(context.chunkSizeFor(110 * MiB), 8 * MiB);
  assert.equal(context.chunkSizeFor(2048 * MiB), 8 * MiB);
});

test('small files still split across the four streams, with a 1 MiB minimum', () => {
  assert.equal(context.chunkSizeFor(12 * MiB), 3 * MiB);
  assert.equal(context.chunkSizeFor(3), MiB);
});

test('very big files grow the chunk to keep about 256 of them, up to 32 MiB', () => {
  assert.equal(context.chunkSizeFor(4096 * MiB), 16 * MiB);
  assert.equal(context.chunkSizeFor(40 * 1024 * MiB), 32 * MiB);
});
