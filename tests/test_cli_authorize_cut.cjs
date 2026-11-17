'use strict';
// The sign-in consent page speaks to InFocus Cut users in its own words (no terminal, no code).
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { readFileSync } = require('node:fs');

const source = readFileSync(new URL('../app/static/cli-authorize.js', `file://${__filename}`), 'utf8');
const html = readFileSync(new URL('../app/static/cli-authorize.html', `file://${__filename}`), 'utf8');

function extract(name) {
  const body = source.match(new RegExp(`^function ${name}\\([^]*?^}`, 'm'));
  assert.ok(body, `Missing ${name}`);
  return body[0];
}

test('InFocus Cut devices are told apart from the terminal', () => {
  const context = vm.createContext({ String });
  vm.runInContext(extract('isInFocusCut'), context);
  assert.equal(context.isInFocusCut('InFocus Cut'), true);
  assert.equal(context.isInFocusCut('InFocus Cut on Media Lab 3'), true);
  assert.equal(context.isInFocusCut('student1-macbook'), false);
  assert.equal(context.isInFocusCut('InFocus Cutter'), false);
  assert.equal(context.isInFocusCut(''), false);
});

test('the page has the elements the InFocus Cut wording replaces', () => {
  for (const id of ['cli-title', 'cli-code-hint', 'cli-code', 'cli-note', 'cli-device']) {
    assert.ok(html.includes(`id="${id}"`), id);
  }
});
