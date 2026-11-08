-- Values that would produce invalid images must fail at validation time.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local t = dofile(root .. '/tests/helper.lua')
t.bootstrap()

local cases = {
    { name = 'dynamic_scale = 0', opts = { dynamic_scale = 0 } },
    { name = 'dynamic_scale = -1', opts = { dynamic_scale = -1 } },
    { name = 'internal_scale = 0', opts = { internal_scale = 0 } },
    { name = 'update_interval = -5', opts = { update_interval = -5 } },
    { name = 'foreground = number', opts = { foreground = 123 } },
    { name = 'filetypes = string', opts = { filetypes = 'markdown' } },
    { name = 'transfer = bogus', opts = { transfer = 'bogus' } },
    { name = 'preview_on_cursor = string', opts = { preview_on_cursor = 'yes' } },
}

for _, case in ipairs(cases) do
    -- A fresh module per case: the first `config.opts` access validates and
    -- freezes the table, so the same instance cannot be re-validated.
    package.loaded['mdmath.config'] = nil
    local config = require'mdmath.config'

    local ok = pcall(function()
        config.set_opts(case.opts)
        return config.opts
    end)

    t.ok(not ok, 'rejects ' .. case.name)
end

t.finish()
