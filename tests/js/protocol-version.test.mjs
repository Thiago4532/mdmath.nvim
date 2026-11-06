// Static guard around the Lua <-> node protocol.
//
// PROTOCOL_VERSION exists in two files, and a mismatch is only detectable at
// runtime, after the plugin actually spawns the processor. Comparing the
// constants here turns "bumped one half only" into a failing test instead of a
// silent `mdmath protocol mismatch` in someone's editor.

import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '../..');
const LUA = path.join(root, 'lua/mdmath/Processor.lua');
const JS = path.join(root, 'mdmath-js/src/processor.js');

function readVersion(file, pattern) {
    const source = readFileSync(file, 'utf8');
    const match = source.match(pattern);
    assert.ok(match, `PROTOCOL_VERSION not found in ${path.relative(root, file)}`);
    return { version: Number(match[1]), source };
}

const lua = readVersion(LUA, /local\s+PROTOCOL_VERSION\s*=\s*(\d+)/);
const js = readVersion(JS, /const\s+PROTOCOL_VERSION\s*=\s*(\d+)/);

test('both halves agree on the protocol version', () => {
    assert.equal(lua.version, js.version,
        'bump PROTOCOL_VERSION in lua/mdmath/Processor.lua and mdmath-js/src/processor.js together');
});

test('the Lua client actually transmits its version', () => {
    // Otherwise the constant could be bumped but never sent, and the gate in
    // processor.js would reject every request with `lua=<missing>`.
    assert.match(lua.source, /args\s*=\s*\{\s*PROCESS_PATH,\s*tostring\(PROTOCOL_VERSION\)\s*\}/);
});

test('the processor validates the incoming version', () => {
    assert.match(js.source, /theirs\s*!==\s*String\(PROTOCOL_VERSION\)/);
    assert.match(js.source, /process\.exit\(2\)/);
});
