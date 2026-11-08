-- The default-on preview must be armed by `setup()` alone: requiring the float
-- module only from `preview()` would leave the autocmds unregistered and the
-- feature silently dead until the user ran the command once.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local t = dofile(root .. '/tests/helper.lua')
t.bootstrap()

local mdmath = require'mdmath'
mdmath.setup({update_interval = 30})
t.stub_image()
t.stub_processor()

local lines = {'$a + b$'}
local bufnr = t.markdown_buffer(lines)
t.full_view(lines)
mdmath.enable(bufnr)

--- Finds the preview's floating window. Neovim reports `relative = 'win'` for a
--- window opened with `relative = 'cursor'` (the cursor anchor is resolved to
--- the window), so any non-normal window is the preview here.
---@return integer|nil
local function preview_win()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(win).relative ~= '' then
            return win
        end
    end
    return nil
end

vim.api.nvim_win_set_cursor(0, {1, 2})
vim.api.nvim_exec_autocmds('CursorMoved', {buffer = bufnr})

t.ok(t.wait_for(function()
    return preview_win() ~= nil
end, 5000), 'setup() alone arms the default-on preview')

local win = preview_win()
if win then
    vim.api.nvim_win_close(win, true)
end

t.finish()
