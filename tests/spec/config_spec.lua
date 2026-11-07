-- Options: defaults, freezing, colour resolution and cell-size fallbacks.
-- `terminfo.size` is stubbed twice, once per fallback case.
---@diagnostic disable: duplicate-set-field

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local t = dofile(root .. '/tests/helper.lua')
t.bootstrap()

require'mdmath'.setup({})

local config = require'mdmath.config'
local opts = config.opts

t.eq(opts.filetypes[1], 'markdown', 'default filetypes')
t.eq(opts.transfer, 'auto', 'default transfer')
t.eq(opts.update_interval, 400, 'default update_interval')
t.ok(opts.foreground:match('^#%x%x%x%x%x%x$') ~= nil, 'foreground resolved to a hex colour')

t.ok(not pcall(function()
    opts.dynamic = false
end), 'writing an existing option is rejected')
t.ok(not pcall(function()
    ---@diagnostic disable-next-line: inject-field
    opts.some_new_option = 1
end), 'writing an unknown option is rejected')
t.ok(not pcall(function()
    ---@diagnostic disable-next-line: missing-fields
    config.opts = {}
end), 'replacing the options table is rejected')

t.ok(not pcall(require'mdmath.util'.hl_as_hex, 'NoSuchHighlightGroup'),
    'unknown highlight group raises instead of formatting nil')

local terminfo = require'mdmath.terminfo'
local real_size = terminfo.size

terminfo.size = function()
    return { row = 40, col = 120, xpixel = 960, ypixel = 800 }
end
local w, h = terminfo.cell_size()
t.eq(w, 8, 'cell width derived from pixel size')
t.eq(h, 20, 'cell height derived from pixel size')

terminfo.size = function()
    return { row = 40, col = 120, xpixel = 0, ypixel = 0 }
end
w, h = terminfo.cell_size()
t.eq(w, 8, 'cell width falls back when pixels are missing')
t.eq(h, 16, 'cell height falls back when pixels are missing')

terminfo.size = function()
    return nil, 25
end
w, h = terminfo.cell_size()
t.eq(w, 8, 'cell width falls back when ioctl fails')
t.eq(h, 16, 'cell height falls back when ioctl fails')

terminfo.size = real_size

t.finish()
