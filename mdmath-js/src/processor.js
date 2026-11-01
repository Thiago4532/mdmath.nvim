import fs from 'fs';
import os from 'os';
import path from 'path';
import mathjax from 'mathjax';
import reader from './reader.js';
import { pngDimensions, pngFitTo, rsvgConvert } from './magick.js';
import { sendNotification, saveFile } from './debug.js';
import { sha256Hash } from './util.js';
import { randomBytes } from 'node:crypto';
import { onExit } from './onexit.js';

// Bumped whenever the wire format changes; the Lua side passes its version as
// argv[2]. A mismatch aborts before stdin is read, so a half-updated install
// fails loudly instead of hanging on a request the other side cannot parse.
const PROTOCOL_VERSION = 1;

// To prevent conflicts with other instances
const DIRECTORY_SUFFIX = randomBytes(3).toString('hex');

const IMG_DIR = path.join(os.tmpdir(), `nvim-mdmath-${DIRECTORY_SUFFIX}`);

/** @typedef {{equation: string, filename: string}} Equation */

/** @type {Equation[]} */
const equations = [];

/** @type {Object.<string, Equation>} */
const equationMap = {};

const svgCache = {};

let internalScale = 1;
let dynamicScale = 1;

let MathJax = undefined;

class MathError extends Error {
    constructor(message) {
        super(message);
        this.name = 'MathError';
    }
}

function mkdirSync(path) {
    try {
        fs.mkdirSync(path, { recursive: true });
    } catch (err) {
        if (err.code !== 'EEXIST')
            throw err;
    }
}

/**
 * @param {string} equation
 * @returns {Promise<{svg: string} | {error: string}>}
 */
async function equationToSVG(equation) {
    if (equation in svgCache)
        return svgCache[equation];

    try {
        const svg = await MathJax.tex2svgPromise(equation);
        return svgCache[equation] = {
            svg: MathJax.startup.adaptor.innerHTML(svg)
        }
    } catch (err) {
        if (err instanceof MathError) {
            return svgCache[equation] = {
                error: err.message
            }
        } else {

        }

        throw err;
    }
}

// The length prefix is counted in bytes, because the Lua side reads a fixed
// number of raw bytes. Using `String#length` (UTF-16 code units) desyncs the
// parser for any non-ASCII payload (file paths, error messages).
function write(identifier, width, height, data) {
    const length = Buffer.byteLength(data, 'utf8');
    process.stdout.write(`${identifier}:image:${width}:${height}:${length}:${data}`);
}

function writeError(identifier, error) {
    error = String(error);
    const length = Buffer.byteLength(error, 'utf8');
    process.stdout.write(`${identifier}:error:0:0:${length}:${error}`);
}

function parseViewbox(svgString) {
    const viewboxMatch = svgString.match(/viewBox="([^"]+)"/);
    if (!viewboxMatch) return null;

    const [minX, minY, width, height] = viewboxMatch[1].split(' ').map(parseFloat);
    return { minX, minY, width, height };
}

/**
  * @param {string} identifier
  * @param {string} equation
*/
async function processEquation(identifier, equation, cWidth, cHeight, width, height, flags, color) {
    if (!equation || equation.trim().length === 0)
        return writeError(identifier, 'Empty equation')

    // The scales are part of the key: changing them changes the rendered pixel
    // dimensions, so a cached entry becomes invalid.
    const equation_key = `${equation}_${cWidth}*${width}x${cHeight}*${height}_${flags}_${color}_${internalScale}x${dynamicScale}`;
    if (equation_key in equationMap) {
        const equationObj = equationMap[equation_key];
        return write(identifier, equationObj.width, equationObj.height, equationObj.filename);
    }

    let {svg, error} = await equationToSVG(equation);
    if (!svg)
        return writeError(identifier, error)

    svg = svg
        .replace(/currentColor/g, color)
        .replace(/style="[^"]+"/, '')

    const isDynamic = !!(flags & 1);

    let basePNG;
    let iWidth, iHeight;
    if (isDynamic) {
        const zoom = 10 * dynamicScale * cHeight * internalScale / 96;
        basePNG = await rsvgConvert(svg, {zoom});

        const {width: pngWidth, height: pngHeight} = await pngDimensions(basePNG);

        const newWidth = (pngWidth / internalScale) / cWidth;
        const newHeight = (pngHeight / internalScale) / cHeight;

        // If the image is smaller than the cell, it's better to keep the original size, so
        width = Math.max(width, Math.ceil(newWidth));
        height = Math.max(height, Math.ceil(newHeight));

        iWidth = width * cWidth * internalScale;
        iHeight = height * cHeight * internalScale;
    } else {
        iWidth = width * cWidth * internalScale;
        iHeight = height * cHeight * internalScale;

        basePNG = await rsvgConvert(svg, {width: iWidth, height: iHeight});
    }

    const hash = sha256Hash(equation).slice(0, 7);
    const isCenter = !!(flags & 2);
    const filename = `${IMG_DIR}/${hash}_${iWidth}x${iHeight}.png`;

    await pngFitTo(basePNG, filename, iWidth, iHeight, {center: isCenter});

    const equationObj = {equation, filename, width, height};
    equations.push(equationObj);
    equationMap[equation_key] = equationObj;

    write(identifier, width, height, filename);
}

function processAll(request) {
    if (request.type === 'request') {
        return processEquation(
            request.identifier,
            request.data,
            request.cellWidth,
            request.cellHeight,
            request.width,
            request.height,
            request.flags,
            request.color
        ).catch((err) => {
            writeError(request.identifier, err.message);
        });
    } else if (request.type === 'dscale') {
        // FIXME: Invalidate cache when scale changes
        dynamicScale = request.scale;
    } else if (request.type === 'iscale') {
        // FIXME: Invalidate cache when scale changes
        internalScale = request.scale;
    }
}

/**
 * Refuses to serve a client that speaks a different wire format.
 *
 * @param {string[]} argv process.argv
 */
function checkProtocol(argv) {
    const theirs = argv[2];
    if (theirs !== String(PROTOCOL_VERSION)) {
        console.error(`mdmath protocol mismatch: lua=${theirs ?? '<missing>'} processor=${PROTOCOL_VERSION}.`
            + ' Reinstall or rebuild the plugin so both halves come from the same commit.');
        process.exit(2);
    }
}

function main() {
    checkProtocol(process.argv);
    mkdirSync(IMG_DIR);

    onExit(() => {
        equations.forEach(({filename}) => {
            try {
                fs.unlinkSync(filename);
            } catch (err) {}
        });

        try {
            fs.rmdirSync(IMG_DIR);
        } catch (err) {}
    });

    mathjax.init({
        loader: { load: ['input/tex', 'output/svg'] },
        tex: {
            formatError: (_, err) => {
                throw new MathError(err.message);
            }
        }
    }).then((MathJax_) => {
        MathJax = MathJax_;
        reader.listen(processAll);
    }).catch((err) => {
        console.error(err);
        process.exit(1);
    });
}

main();
