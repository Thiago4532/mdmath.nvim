-- Mark lifecycle: reuse on unrelated edits, re-render on clear, stop on disable,
-- and isolation between buffers. The IPC layer is stubbed so the spec is fast
-- and deterministic; `render_spec` covers the real pipeline.

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
    'inline $a + b$ text',
    '',
    '$$',
    'c + d',
    '$$',
}
t.full_view(lines)

local bufnr = t.markdown_buffer(lines)
mdmath.enable(bufnr)

t.ok(t.wait_for(function()
    return #added >= 2
end), 'two equations render')

local after_render = #added
t.eq(after_render, 2, 'one mark per equation')

-- An edit elsewhere must reuse the existing equations, not re-render them.
vim.api.nvim_buf_set_lines(bufnr, #lines, #lines, false, { 'tail' })
vim.wait(300)
t.eq(#added, after_render, 'unrelated edit reuses equations')

-- `clear` invalidates and renders again.
mdmath.clear(bufnr)
t.ok(t.wait_for(function()
    return #added > after_render
end), 'clear re-renders')

local after_clear = #added

-- Disabled buffers must stop reacting to edits.
mdmath.disable(bufnr)
vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { 'prepended' })
vim.wait(300)
t.eq(#added, after_clear, 'disable stops rendering')

-- A second buffer renders independently.
local other = t.markdown_buffer({ '$y^2$' })
mdmath.enable(other)
t.ok(t.wait_for(function()
    local n = 0
    for _, mark in ipairs(added) do
        if mark.bufnr == other then
            n = n + 1
        end
    end
    return n > 0
end), 'second buffer renders')

local foreign = 0
for _, mark in ipairs(added) do
    if mark.bufnr == bufnr then
        foreign = foreign + 1
    end
end
t.eq(foreign, after_clear, 'disabled buffer receives no new marks')

mdmath.disable(other)
t.finish()
