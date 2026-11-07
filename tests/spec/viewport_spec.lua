-- Regression: a block whose opening fence sits above the viewport must still be
-- captured while any part of it is visible.
---@diagnostic disable: duplicate-set-field
--
-- The old implementation passed the viewport to `iter_captures`, which filters
-- by capture *start* row: the block was skipped, no Equation was created, and it
-- never appeared until something forced a re-parse with a different viewport.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local t = dofile(root .. '/tests/helper.lua')
t.bootstrap()
t.skip_without_injection()

local mdmath = require'mdmath'
mdmath.setup({ update_interval = 30 })
t.stub_image()
t.stub_processor()

local added = t.collect_marks()

local lines = {
    '$$',        -- row 0: opening fence, above the viewport
    'a + b = c', -- row 1
    '$$',        -- row 2
    '',
    'tail',      -- row 4
}

local util = require'mdmath.util'

-- Viewport starts inside the block (row 1), so only rows 1..3 are "visible".
util.get_current_view = function()
    return 1, 4
end

local bufnr = t.markdown_buffer(lines)
mdmath.enable(bufnr)

t.ok(t.wait_for(function()
    return #added >= 1
end), 'block overlapping the viewport top is rendered')

t.eq(added[1] and added[1].row, 0, 'mark is placed on the block start row')

-- A viewport entirely below the block must not render it.
util.get_current_view = function()
    return 4, 5
end

local before = #added
local below = t.markdown_buffer(lines)
mdmath.enable(below)
vim.wait(300)

local below_marks = 0
for _, mark in ipairs(added) do
    if mark.bufnr == below then
        below_marks = below_marks + 1
    end
end
t.eq(below_marks, 0, 'equation outside the viewport is not rendered')
t.eq(#added, before, 'no marks were added for the off-screen buffer')

mdmath.disable(below)
mdmath.disable(bufnr)
t.finish()
