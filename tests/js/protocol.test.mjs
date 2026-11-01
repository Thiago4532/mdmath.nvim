// IPC contract tests: protocol version gate and byte-length framing.
//
// The processor is spawned for real (MathJax included); only the framing and the
// version handshake are asserted, no rendering output is inspected.

import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '../..');
const processor = path.join(root, 'mdmath-js/src/processor.js');

const hasDeps = existsSync(path.join(root, 'mdmath-js/node_modules/mathjax'));
const skip = hasDeps ? false : 'mdmath-js/node_modules is missing (run :MdMath build)';

/** @param {string[]} args */
function start(args) {
    const child = spawn('node', [processor, ...args], { stdio: ['pipe', 'pipe', 'pipe'] });
    const started = { child, stderr: '' };
    child.stderr.on('data', (chunk) => {
        started.stderr += chunk;
    });
    return started;
}

test('rejects a mismatched protocol version', { skip }, async () => {
    const started = start(['999']);
    const code = await new Promise((resolve) => started.child.on('exit', resolve));

    assert.equal(code, 2);
    assert.match(started.stderr, /protocol mismatch/);
});

test('frames non-ASCII payloads by byte length', { skip }, async () => {
    const { child } = start(['1']);

    const equation = '\\text{中文} + \\alpha = \\beta';
    const payload = Buffer.from(equation, 'utf8');
    const header = `1:request:2:#ff0000:8:12:16:1:${payload.length}:`;
    child.stdin.write(Buffer.concat([Buffer.from(header, 'utf8'), payload]));

    let buffer = Buffer.alloc(0);
    /** @type {{type: string, width: number, height: number, data: string}|null} */
    let message = null;

    const parsed = await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('timed out waiting for a response')), 30000);

        child.stdout.on('data', (chunk) => {
            buffer = Buffer.concat([buffer, chunk]);

            let pos = 0;
            const fields = [];
            for (let i = 0; i < 5; i++) {
                const idx = buffer.indexOf(0x3a, pos);
                if (idx === -1) return;
                fields.push(buffer.toString('utf8', pos, idx));
                pos = idx + 1;
            }

            const length = Number(fields[4]);
            assert.ok(Number.isInteger(length) && length >= 0, `bad length field: ${fields[4]}`);
            if (buffer.length < pos + length) return;

            message = {
                type: fields[1],
                width: Number(fields[2]),
                height: Number(fields[3]),
                data: buffer.toString('utf8', pos, pos + length),
            };
            clearTimeout(timer);
            resolve(message);
        });
    });

    assert.equal(parsed.type, 'image', parsed.data);
    assert.ok(parsed.width > 0, 'response carries a cell width');
    assert.ok(parsed.height > 0, 'response carries a cell height');
    assert.match(parsed.data, /\.png$/, 'response carries the rendered file path');

    child.kill('SIGTERM');
    await new Promise((resolve) => child.on('exit', resolve));
});
