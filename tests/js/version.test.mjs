// The plugin version has one source of truth: lua/mdmath/version.lua.
// `mdmath-js` is an internal dependency, but its package files must not drift or
// `npm ci` and the release tag end up disagreeing.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '../..');

const match = readFileSync(path.join(root, 'lua/mdmath/version.lua'), 'utf8')
    .match(/return\s+'([^']+)'/);
assert.ok(match, 'lua/mdmath/version.lua must return a version string');
const version = match[1];

const pkg = JSON.parse(readFileSync(path.join(root, 'mdmath-js/package.json'), 'utf8'));
const lock = JSON.parse(readFileSync(path.join(root, 'mdmath-js/package-lock.json'), 'utf8'));

test('package.json matches the Lua version', () => {
    assert.equal(pkg.version, version);
});

test('package-lock.json matches the Lua version', () => {
    assert.equal(lock.version, version);
    assert.equal(lock.packages[''].version, version);
});

test('the version is a plain semver without a leading v', () => {
    assert.match(version, /^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/);
});
