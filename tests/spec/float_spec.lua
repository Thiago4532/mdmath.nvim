-- Floating preview: scratch buffer contents, id colouring, replacement and
-- lifecycle (cursor movement, close), plus the equation lookup used by
-- `:MdMath preview`.
--
-- The renderer and the Kitty transport are stubbed; this spec is about the
-- window/buffer layer.
---@diagnostic disable: duplicate-set-field

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local t = dofile(root .. '/tests/helper.lua')
t.bootstrap()

local mdmath = require'mdmath'
mdmath.setup({update_interval = 30})
t.stub_image()
t.stub_processor()

local float = require'mdmath.float'

local function preview(tex, opts)
    local win, err
    mdmath.preview(tex, opts, function(w, e)
        win, err = w, e
    end)
    t.wait_for(function()
        return win ~= nil or err ~= nil
    end, 5000)
    return win, err
end

local win, err = preview('a + b', {width = 3, height = 2})
t.eq(err, nil, 'preview renders without error')
t.ok(win ~= nil and vim.api.nvim_win_is_valid(win), 'preview opens a window')
t.eq(float.win(), win, 'win() reports the open preview')

local buf = vim.api.nvim_win_get_buf(win)
t.eq(vim.api.nvim_buf_line_count(buf), 2, 'one buffer line per image row')
local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
t.eq(vim.fn.strdisplaywidth(lines[1]), 3, 'one placeholder cell per image column')
t.eq(vim.bo[buf].modifiable, false, 'preview buffer is read-only')

local ns = vim.api.nvim_create_namespace('mdmath-float')
local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {details = true})
t.eq(#marks, 2, 'each row carries the image id highlight')
t.eq(vim.api.nvim_win_get_config(win).focusable, false, 'preview is not focusable')
t.ok(vim.wo[win].winhl:find('Normal:Normal', 1, true) ~= nil,
    'preview shares the editor Normal instead of NormalFloat')
t.ok(vim.wo[win].winhl:find('MdMathPreviewBorder', 1, true) ~= nil,
    'preview maps FloatBorder to the transparent group')
local normal_bg = vim.api.nvim_get_hl(0, {name = 'Normal', link = false}).bg
t.eq(vim.api.nvim_get_hl(0, {name = 'MdMathPreviewBorder'}).bg, normal_bg,
    'the border uses the editor background')

-- A second preview replaces the first instead of stacking windows.
local first = win
local second = preview('c + d', {width = 1, height = 1})
t.ok(second ~= nil and vim.api.nvim_win_is_valid(second), 'second preview opens')
t.eq(vim.api.nvim_win_is_valid(first), false, 'the previous preview is closed')

-- Any cursor movement dismisses the preview.
vim.api.nvim_exec_autocmds('CursorMoved', {})
t.eq(float.win(), nil, 'cursor movement closes the preview')

-- Renderer failures must not open a window.
local Processor = require'mdmath.Processor'
local real_from_bufnr = Processor.from_bufnr
Processor.from_bufnr = function()
    return {
        request = function(_, _, _, _, _, _, _, _, callback)
            vim.schedule(function()
                callback(nil, 'bad math')
            end)
        end,
    }
end
win, err = preview('\\frac{')
t.eq(win, nil, 'render error returns no window')
t.eq(err, 'bad math', 'render error is forwarded')
Processor.from_bufnr = real_from_bufnr

float.close()
t.eq(float.win(), nil, 'close() is idempotent')

-- `:MdMath preview` resolves the equation under the cursor.
if t.has_injection_query() then
    local bufnr = t.markdown_buffer({'x $a + b$ y'})

    vim.api.nvim_win_set_cursor(0, {1, 4})
    t.eq(float.equation_under_cursor(bufnr), 'a + b', 'cursor inside an inline equation')

    vim.api.nvim_win_set_cursor(0, {1, 0})
    t.eq(float.equation_under_cursor(bufnr), nil, 'cursor outside equations')

    vim.api.nvim_win_set_cursor(0, {1, 4})
    -- Plugin scripts are not sourced by `--clean`; the spec loads it explicitly
    -- so the user command exists.
    vim.cmd.source(root .. '/plugin/mdmath.lua')
    t.ok(pcall(function()
        vim.cmd('MdMath preview')
    end), ':MdMath preview runs')
    t.ok(t.wait_for(function()
        return float.win() ~= nil
    end, 5000), ':MdMath preview opens a window')

    vim.api.nvim_exec_autocmds('CursorMoved', {})
    t.eq(float.win(), nil, 'the command preview closes on cursor movement')
    -- Cancel the auto-preview timer armed by that event before the next block.
    float.close()
else
    t.skip('equation under the cursor', 'markdown_inline injections unavailable')
end

-- Default-on: the preview opens by itself once the cursor rests on an equation.
if t.has_injection_query() then
    local lines = {'$a + b$', 'plain text'}
    local auto_buf = t.markdown_buffer(lines)
    t.full_view(lines)
    mdmath.enable(auto_buf)

    vim.api.nvim_win_set_cursor(0, {1, 2})
    vim.api.nvim_exec_autocmds('CursorMoved', {buffer = auto_buf})
    t.ok(t.wait_for(function()
        return float.win() ~= nil
    end, 5000), 'preview opens when the cursor rests on an equation')

    vim.api.nvim_win_set_cursor(0, {2, 0})
    vim.api.nvim_exec_autocmds('CursorMoved', {buffer = auto_buf})
    t.eq(float.win(), nil, 'moving off the equation closes the preview')
    t.ok(not t.wait_for(function()
        return float.win() ~= nil
    end, 500), 'no preview opens off an equation')

    vim.api.nvim_win_set_cursor(0, {1, 2})
    vim.api.nvim_exec_autocmds('CursorMoved', {buffer = auto_buf})
    t.ok(t.wait_for(function()
        return float.win() ~= nil
    end, 5000), 'preview reopens when the cursor returns to the equation')
    float.close()
else
    t.skip('preview on cursor rest', 'markdown_inline injections unavailable')
end

t.finish()
