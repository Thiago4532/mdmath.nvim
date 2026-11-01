-- End-to-end render of the manual checklist: the real node/MathJax process is
-- exercised, only the Kitty transport is stubbed (there is no TTY headless).
--
-- Expectations are tied to tests/manual/mdmath-test.md: 15 equations render and
-- one deliberately broken environment produces an inline error.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local t = dofile(root .. '/tests/helper.lua')
t.bootstrap()
t.skip_without_injection()

local ok_deps, reason = t.has_render_deps(root)
if not ok_deps then
    t.skip('render pipeline', reason)
    t.finish()
end

local mdmath = require'mdmath'
mdmath.setup({ update_interval = 50 })
t.stub_image()

local doc = root .. '/tests/manual/mdmath-test.md'
local lines = vim.fn.readfile(doc)
t.full_view(lines)

local added = t.collect_marks()
local bufnr = t.markdown_buffer(lines)

mdmath.enable(bufnr)

local rendered = t.wait_for(function()
    return #added >= 16
end, 60000)

t.ok(rendered, 'all checklist equations rendered')

local images, errors, error_row = 0, 0, nil
for _, mark in ipairs(added) do
    if mark.opts.color == 'Error' then
        errors = errors + 1
        error_row = mark.row
    else
        images = images + 1
    end
end

t.eq(images, 15, 'image marks')
t.eq(errors, 1, 'error marks')

local expected_error_row
for i, line in ipairs(lines) do
    if line:find('unknownenv', 1, true) then
        expected_error_row = i - 1
    end
end
t.eq(error_row, expected_error_row, 'error mark sits on the failing equation')

-- Every mark must belong to the buffer we enabled.
local foreign = 0
for _, mark in ipairs(added) do
    if mark.bufnr ~= bufnr then
        foreign = foreign + 1
    end
end
t.eq(foreign, 0, 'all marks belong to the enabled buffer')

mdmath.disable(bufnr)
t.finish()
