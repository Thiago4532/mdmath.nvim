import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { sha256Hash } from '../../mdmath-js/src/util.js';

const expected = (value) => createHash('sha256').update(value, 'utf8').digest('hex');

test('sha256Hash is content addressed', () => {
    assert.equal(sha256Hash('a + b'), expected('a + b'));
    assert.equal(sha256Hash('中文 + \\alpha'), expected('中文 + \\alpha'));
});

test('sha256Hash is stateless', () => {
    // The old implementation shared one hash instance, so the second digest
    // included the first payload.
    assert.equal(sha256Hash('first'), expected('first'));
    assert.equal(sha256Hash('second'), expected('second'));
    assert.notEqual(sha256Hash('first'), sha256Hash('second'));
});
