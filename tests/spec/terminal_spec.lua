-- A terminal that implements Kitty graphics but not Unicode placeholders must not
-- get placeholder glyphs: the plugin keeps the source text and warns once.
-- `vim.g.mdmath_force_placeholders` overrides the detection.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local t = dofile(root .. '/tests/helper.lua')
t.bootstrap()
t.skip_without_injection()

local mdmath = require'mdmath'
mdmath.setup({ update_interval = 30 })
t.stub_image()
t.stub_processor()

local added = t.collect_marks()

-- Pretend to be WezTerm: known to implement the graphics protocol but not
-- Unicode placeholders. The classification is read when `enable()` runs.
vim.env.TERM = 'xterm-256color'
vim.env.TERM_PROGRAM = 'WezTerm'
vim.env.KITTY_WINDOW_ID = nil
vim.g.mdmath_force_placeholders = nil

local notifications = {}
local real_notify = vim.notify
vim.notify = function(msg)
    notifications[#notifications + 1] = tostring(msg)
end

t.full_view({ '$a + b$' })
local bufnr = t.markdown_buffer({ '$a + b$' })
mdmath.enable(bufnr)

vim.wait(500)
t.eq(#added, 0, 'no marks are created without placeholder support')

local warned = false
for _, message in ipairs(notifications) do
    if message:find('Unicode placeholders', 1, true) then
        warned = true
    end
end
t.ok(warned, 'the user is told once why nothing renders')

-- The escape hatch must still work, e.g. for a terminal that gained support.
vim.g.mdmath_force_placeholders = 1
local forced = t.markdown_buffer({ '$y^2$' })
mdmath.enable(forced)
t.ok(t.wait_for(function()
    return #added > 0
end, 10000), 'vim.g.mdmath_force_placeholders bypasses the detection')

vim.g.mdmath_force_placeholders = nil
vim.notify = real_notify
mdmath.disable(bufnr)
t.finish()
