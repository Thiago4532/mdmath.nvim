-- Out-of-line preview pane and the live (insert-mode) refresh of the preview.
-- Rendering and the Kitty transport are stubbed; the assertions are about the
-- window lifecycle and about which TeX reaches the renderer.
---@diagnostic disable: duplicate-set-field

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local t = dofile(root .. '/tests/helper.lua')
t.bootstrap()

local mdmath = require'mdmath'
mdmath.setup({update_interval = 30, preview_on_cursor = false})
t.stub_image()

-- Recording renderer: the last requested TeX tells us what is on screen.
local Processor = require'mdmath.Processor'
local requests = {}
Processor.from_bufnr = function()
    return {
        request = function(_, data, _, _, width, height, _, _, callback)
            requests[#requests + 1] = data
            vim.schedule(function()
                callback({width = width, height = height, data = '/tmp/mdmath-pane.png'}, nil)
            end)
        end,
    }
end

local float = require'mdmath.float'

local lines = {'$a + b$', 'plain text'}
local bufnr = t.markdown_buffer(lines)
t.full_view(lines)
mdmath.enable(bufnr)

local function last_request()
    return requests[#requests]
end

-- Pane: docked preview of the equation under the cursor.
vim.api.nvim_win_set_cursor(0, {1, 2})
mdmath.pane()
t.ok(t.wait_for(function()
    return float.pane_win() ~= nil
end, 5000), 'pane opens on the equation')

local win = assert(float.pane_win())
local pane_buf = vim.api.nvim_win_get_buf(win)
t.eq(vim.api.nvim_buf_line_count(pane_buf), 1, 'pane shows the rendered rows')
t.eq(last_request(), 'a + b', 'pane rendered the equation under the cursor')
t.eq(vim.api.nvim_win_get_config(win).relative, 'editor', 'pane is docked to the editor')
t.eq(vim.bo[pane_buf].modifiable, false, 'pane buffer is read-only')

-- Cursor leaves the equation: the pane hides but stays enabled.
vim.api.nvim_win_set_cursor(0, {2, 0})
vim.api.nvim_exec_autocmds('CursorMoved', {buffer = bufnr})
t.ok(t.wait_for(function()
    return float.pane_win() == nil
end, 5000), 'pane hides when no equation is under the cursor')
t.ok(float.pane_enabled(), 'pane stays enabled while hidden')

-- Back on the equation: it reappears.
vim.api.nvim_win_set_cursor(0, {1, 2})
vim.api.nvim_exec_autocmds('CursorMoved', {buffer = bufnr})
t.ok(t.wait_for(function()
    return float.pane_win() ~= nil
end, 5000), 'pane reappears on the equation')

-- Live edit while the pane is open.
local before = #requests
vim.api.nvim_exec_autocmds('InsertEnter', {buffer = bufnr})
vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {'$a + c$'})
vim.api.nvim_exec_autocmds('TextChangedI', {buffer = bufnr})
t.ok(t.wait_for(function()
    return #requests > before
end, 5000), 'pane re-renders after an edit')
t.eq(last_request(), 'a + c', 'pane follows the edited equation')
t.ok(float.pane_win() ~= nil, 'pane stays open while typing')
vim.api.nvim_exec_autocmds('InsertLeave', {buffer = bufnr})

-- Toggle off.
mdmath.pane()
t.eq(float.pane_enabled(), false, 'pane toggles off')
t.eq(float.pane_win(), nil, 'pane window is closed')

-- Live cursor preview: Insert mode must keep it and follow edits.
local image, err
mdmath.preview('a + c', nil, function(i, e)
    image, err = i, e
end)
t.wait_for(function()
    return image ~= nil or err ~= nil
end, 5000)
t.ok(float.win() ~= nil, 'manual preview opens')

vim.api.nvim_exec_autocmds('InsertEnter', {buffer = bufnr})
t.ok(float.win() ~= nil, 'insert mode keeps the preview')

before = #requests
vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {'$a + e$'})
vim.api.nvim_exec_autocmds('TextChangedI', {buffer = bufnr})
t.ok(t.wait_for(function()
    return #requests > before
end, 5000), 'preview re-renders after an edit')
t.eq(last_request(), 'a + e', 'preview follows the edited equation')
t.ok(float.win() ~= nil, 'preview stays open while typing')
vim.api.nvim_exec_autocmds('InsertLeave', {buffer = bufnr})

float.close()
t.eq(float.win(), nil, 'close() dismisses the live preview')

-- User command: `:MdMath pane` toggles the pane.
vim.cmd.source(root .. '/plugin/mdmath.lua')
t.ok(pcall(function()
    vim.cmd('MdMath pane')
end), ':MdMath pane runs')
t.ok(float.pane_enabled(), ':MdMath pane enables the pane')
vim.cmd('MdMath pane')
t.eq(float.pane_enabled(), false, ':MdMath pane toggles off')

t.finish()
