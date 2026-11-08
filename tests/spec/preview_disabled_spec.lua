-- `preview_on_cursor = false` keeps the floating preview strictly on-demand:
-- resting on an equation must not open a window, while `preview()` still does.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local t = dofile(root .. '/tests/helper.lua')
t.bootstrap()

local mdmath = require'mdmath'
mdmath.setup({preview_on_cursor = false, update_interval = 30})
t.stub_image()
t.stub_processor()

local float = require'mdmath.float'

local lines = {'$a + b$'}
local bufnr = t.markdown_buffer(lines)
t.full_view(lines)
mdmath.enable(bufnr)

vim.api.nvim_win_set_cursor(0, {1, 2})
vim.api.nvim_exec_autocmds('CursorMoved', {buffer = bufnr})
t.ok(not t.wait_for(function()
    return float.win() ~= nil
end, 500), 'no automatic preview when disabled')

local win, err
mdmath.preview('a + b', nil, function(w, e)
    win, err = w, e
end)
t.ok(t.wait_for(function()
    return win ~= nil or err ~= nil
end, 5000), 'manual preview still renders')
t.eq(err, nil, 'manual preview has no error')
t.ok(win ~= nil and vim.api.nvim_win_is_valid(win), 'manual preview opens a window')

float.close()
t.eq(float.win(), nil, 'close() closes the manual preview')

t.finish()
