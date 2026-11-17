const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const vm = require('node:vm');

const source = readFileSync(`${__dirname}/../app/static/editing-ui.js`, 'utf8');
const fn = source.match(/^export function initials\([^]*?^}/m)[0].replace('export ', '');
const context = vm.createContext({});
vm.runInContext(fn, context);

test('initials take the first letter of the first and last word', () => {
  assert.equal(context.initials('Student Two'), 'ST');
  assert.equal(context.initials('Student Three'), 'ST');
  assert.equal(context.initials('  ada  b  lovelace '), 'AL');
});

test('a single word gives its first two letters', () => {
  assert.equal(context.initials('student1'), 'ST');
  assert.equal(context.initials('A'), 'A');
  assert.equal(context.initials(''), '?');
});

test('every avatar uses the same rule, with no per-page disambiguation', () => {
  const pages = ['editing-ui.js', 'editing.js', 'editing-detail.js']
    .map((f) => readFileSync(`${__dirname}/../app/static/${f}`, 'utf8'));
  for (const page of pages) assert.doesNotMatch(page, /distinctInitials/);
});
