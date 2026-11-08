-- Callback API: argument validation, colour resolution, success and error
-- paths. The renderer and the Kitty transport are stubbed: this spec is about
-- the API contract, not about MathJax (see api_render_spec).
---@diagnostic disable: duplicate-set-field

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local t = dofile(root .. '/tests/helper.lua')
t.bootstrap()

local mdmath = require'mdmath'
mdmath.setup({})
t.stub_image()

-- Replace the IPC client so the spec can inspect the request and choose the
-- response. Must come after `setup()`: loading Processor reads the options.
local Processor = require'mdmath.Processor'
---@type table<string, any>
local captured = {}
local reply = 'ok'

Processor.from_bufnr = function()
    return {
        request = function(_, data, cell_width, cell_height, width, height, flags, color, callback)
            captured = {
                data = data,
                cell_width = cell_width,
                cell_height = cell_height,
                width = width,
                height = height,
                flags = flags,
                color = color,
            }
            vim.schedule(function()
                if reply == 'error' then
                    callback(nil, 'bad math')
                else
                    callback({ width = width, height = height, data = '/tmp/mdmath-api.png' }, nil)
                end
            end)
        end,
    }
end

--- Renders and waits for the callback. Also returns the call count.
local function call(tex, opts)
    local image, err, calls = nil, nil, 0
    mdmath.render(tex, opts, function(i, e)
        calls = calls + 1
        image, err = i, e
    end)
    t.wait_for(function()
        return calls > 0
    end, 5000)
    return image, err, calls
end

-- Argument misuse is a programming error, not a render failure.
t.ok(not pcall(mdmath.render, 42, nil, function() end), 'non-string tex raises')
t.ok(not pcall(mdmath.render, 'a', nil, 42), 'non-function callback raises')
t.ok(not pcall(mdmath.render, 'a', {width = 0}, function() end), 'width below 1 raises')

-- An empty equation is rejected before the renderer is spawned.
local image, err, calls = call('   ')
t.eq(calls, 1, 'empty equation calls the callback once')
t.eq(image, nil, 'empty equation returns no image')
t.eq(err, 'empty equation', 'empty equation error')

-- Defaults: one cell, dynamic sizing, config foreground, queried cell size.
image, err = call('a + b')
t.eq(err, nil, 'default render succeeds')
t.ok(image ~= nil, 'default render returns an image')
---@cast image mdmath.Image
t.eq(captured.data, 'a + b', 'TeX is forwarded verbatim')
t.eq(captured.width, 1, 'default width in cells')
t.eq(captured.height, 1, 'default height in cells')
t.eq(captured.flags, 1, 'dynamic sizing is on by default')
t.ok(captured.color:match('^#%x%x%x%x%x%x$') ~= nil, 'colour resolved to hex')
t.ok(captured.cell_width >= 1 and captured.cell_height >= 1, 'cell size is positive')
t.eq(image.rows, captured.height, 'image rows come from the renderer height')
t.eq(image.cols, captured.width, 'image cols come from the renderer width')
t.eq(image.path, '/tmp/mdmath-api.png', 'image exposes the PNG path')

-- Explicit options.
image, err = call('x', {
    width = 4,
    height = 2,
    dynamic = false,
    center = true,
    color = '#00ff00',
    cell_width = 10,
    cell_height = 20,
})
t.eq(err, nil, 'explicit options render')
t.eq(captured.width, 4, 'explicit cell width')
t.eq(captured.height, 2, 'explicit cell height')
t.eq(captured.flags, 2, 'no dynamic bit, centered bit set')
t.eq(captured.color, '#00ff00', 'hex colour is passed through')
t.eq(captured.cell_width, 10, 'explicit cell pixel width')
t.eq(captured.cell_height, 20, 'explicit cell pixel height')

-- Renderer failures travel through the callback.
reply = 'error'
image, err, calls = call('\\frac{')
t.eq(calls, 1, 'renderer error calls the callback once')
t.eq(image, nil, 'renderer error returns no image')
t.eq(err, 'bad math', 'renderer error message is forwarded')
reply = 'ok'

-- A bad colour is reported through the callback, not raised.
image, err = call('x', {color = 'NoSuchHighlightGroup'})
t.eq(image, nil, 'unknown highlight group returns no image')
t.ok(err ~= nil and err:find('neither a hex color', 1, true) ~= nil,
    'unknown highlight group error')

-- No TTY: Image.new returns nil, the API must report it.
local Image = require'mdmath.Image'
local real_new = Image.new
Image.new = function()
    return nil
end
image, err = call('x')
t.eq(image, nil, 'missing TTY returns no image')
t.ok(err ~= nil and err:find('TTY', 1, true) ~= nil, 'missing TTY error')
Image.new = real_new

-- The callback is asynchronous even for errors, so callers only see one order.
calls = 0
mdmath.render('   ', nil, function()
    calls = calls + 1
end)
t.eq(calls, 0, 'callback is not invoked synchronously')
t.wait_for(function()
    return calls > 0
end, 5000)
t.eq(calls, 1, 'callback runs on the next event-loop turn')

t.finish()
