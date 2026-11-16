const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const vm = require('node:vm');

const formatUrl = new URL('../app/static/format.js', `file://${__filename}`);
const appSource = readFileSync(new URL('../app/static/app.js', `file://${__filename}`), 'utf8');

const project = { name: 'Robotics.fcteam', path: 'Team Projects/Robotics.fcteam', is_dir: true };
const folder = { name: 'Robotics Media', path: 'Team Projects/Robotics Media', is_dir: true };
const file = { name: 'notes.fcteam', path: 'Team Projects/notes.fcteam', is_dir: false };

test('a .fcteam folder is one InFocus Cut project, not a browsable folder', async () => {
  const f = await import(formatUrl);
  assert.equal(f.isTeamProject(project), true);
  assert.equal(f.isTeamProject({ ...project, name: 'ROBOTICS.FCTEAM' }), true);
  assert.equal(f.isTeamProject(folder), false);
  assert.equal(f.isTeamProject(file), false);
  assert.equal(f.isBrowsableFolder(project), false);
  assert.equal(f.isBrowsableFolder(folder), true);
  assert.equal(f.describeKind(project).label, 'InFocus Cut project');
  assert.equal(f.describeKind(folder).label, 'Folder');
});

function extract(name) {
  const body = appSource.match(new RegExp(`^(?:async )?function ${name}\\([^]*?^}`, 'm'));
  assert.ok(body, `Missing ${name}`);
  return body[0];
}

test('opening a team project shows a hint instead of navigating into it', async () => {
  const f = await import(formatUrl);
  const calls = { navigate: [], toasts: [] };
  const context = vm.createContext({
    isTeamProject: f.isTeamProject,
    previewKind: f.previewKind,
    navigate: (path) => calls.navigate.push(path),
    toast: (message) => calls.toasts.push(message),
    openPreview() {},
    downloadItems() {},
  });
  vm.runInContext(extract('openItem'), context);
  context.openItem(project);
  assert.deepEqual(calls.navigate, []);
  assert.match(calls.toasts[0], /InFocus Cut/);
  context.openItem(folder);
  assert.deepEqual(calls.navigate, ['Team Projects/Robotics Media']);
});

test('row and tile clicks, folder drops and the tree skip team projects', () => {
  for (const snippet of [
    'if (isBrowsableFolder(item)) bindFolderDrop(row, item.path);',
    'if (isBrowsableFolder(item)) bindFolderDrop(tile, item.path);',
    'state.treeChildren[path] = (data.items || []).filter(isBrowsableFolder);',
    'class: `row${isBrowsableFolder(item) ? " row--folder" : ""}',
  ]) {
    assert.ok(appSource.includes(snippet), snippet);
  }
  assert.equal((appSource.match(/if \(isBrowsableFolder\(item\) \|\| previewKind\(item\)\) \{/g) || []).length, 2);
});
