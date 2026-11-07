-- Stress/diagnostic harness for mdmath.nvim.
-- The stubs below deliberately replace module functions more than once.
---@diagnostic disable: duplicate-set-field
--
-- Drives the render pipeline over the manual test document with a real cell
-- size, repeatedly changing the viewport, and checks that every equation that
-- overlaps the viewport ends up with a live mark.
--
-- Records plugin-level errors, orphan protocol responses, and mark churn, which
-- is what "some equations stop rendering after a restart" looks like from
-- inside the plugin.
--
-- Usage (headless):     nvim --headless --clean -l tests/manual/stress.lua
-- Usage (interactive):  :luafile tests/manual/stress.lua

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
vim.opt.rtp:prepend(plugin_root)
pcall(function()
    vim.opt.rtp:append(vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter/runtime'))
end)

local doc = plugin_root .. '/tests/manual/mdmath-test.md'
local lines = vim.fn.readfile(doc)
local CYCLES = tonumber(vim.env.MDMATH_STRESS_CYCLES) or 12

local mdmath = require'mdmath'
mdmath.setup({update_interval = 40})

require'mdmath.terminfo'.size = function()
    return {row = 40, col = 120, xpixel = 2048, ypixel = 1488}
end

local errors = {}
local util = require'mdmath.util'
local real_err_message = util.err_message
util.err_message = function(...)
    errors[#errors + 1] = table.concat(vim.iter({...}):flatten():totable())
    return real_err_message(...)
end

local Processor = require'mdmath.Processor'
local orphan_responses = 0
local real_on_data = Processor._on_data
Processor._on_data = function(self, identifier, data_type, width, height, data)
    if self.callbacks and not self.callbacks[identifier] then
        orphan_responses = orphan_responses + 1
    end
    return real_on_data(self, identifier, data_type, width, height, data)
end

local Image = require'mdmath.Image'
local image_count = 0
Image.new = function(rows, cols)
    local self = {id = 1, rows = rows, cols = cols}
    function self:text()
        local out = {}
        for row = 1, rows do
            local cells = {}
            for col = 1, cols do
                cells[#cells + 1] = Image.unicode_at(row, col)
            end
            out[#out + 1] = table.concat(cells)
        end
        return out
    end
    function self:color() return self.id end
    function self:close() end
    image_count = image_count + 1
    return self
end

-- Track live marks by id (add/remove), so a mark that is created and then
-- dropped in the same cycle is not counted as success.
local marks = require'mdmath.marks'
local live = {}
local real_add = marks.add
local real_remove = marks.remove
marks.add = function(bufnr, row, col, opts)
    local id = real_add(bufnr, row, col, opts)
    if id then
        live[id] = row
    end
    return id
end
marks.remove = function(bufnr, id)
    live[id] = nil
    return real_remove(bufnr, id)
end

local view = {0, #lines}
util.get_current_view = function()
    return view[1], view[2]
end

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(bufnr)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
vim.bo[bufnr].filetype = 'markdown'

-- Expected equations: every latex_block overlapping the given viewport.
local parser = assert(vim.treesitter.get_parser(bufnr, 'markdown'))
-- `parse()` without a range does not process injections on 0.12, so the
-- `markdown_inline` child would be missing and every expectation would be zero.
parser:parse({0, #lines})
local query = vim.treesitter.query.parse('markdown_inline', '(latex_block) @block')
local ranges = {}
local inlines = parser:children()['markdown_inline']
if inlines then
    inlines:for_each_tree(function(tree)
        for _, node in query:iter_captures(tree:root(), bufnr) do
            local sr, _, er = node:range()
            ranges[#ranges + 1] = {sr, er}
        end
    end)
end

local function expected_for(start_row, end_row)
    local n = 0
    for _, range in ipairs(ranges) do
        if range[2] >= start_row and range[1] < end_row then
            n = n + 1
        end
    end
    return n
end

local function wait_live(count, timeout)
    return vim.wait(timeout, function()
        return #vim.tbl_keys(live) >= count
    end, 25)
end

local function run_cycle(label, start_row, end_row)
    view = {start_row, end_row}
    live = {}
    image_count = 0

    mdmath.clear(bufnr)
    local expected = expected_for(start_row, end_row)
    local ok = wait_live(expected, 15000)

    local got = #vim.tbl_keys(live)
    print(string.format('%-6s view=%3d..%3d expected=%2d live=%2d ok=%s images=%d errors=%d orphans=%d',
        label, start_row, end_row, expected, got, tostring(ok), image_count, #errors, orphan_responses))
    return ok and got == expected
end

mdmath.enable(bufnr)
local all_ok = true
all_ok = run_cycle('init', 0, #lines) and all_ok

local offsets = {0, 8, 16, 24, 32, 40, 48, 54, 60, 66, 72, 78, 84, 90, 96}

for i = 1, CYCLES do
    local offset = offsets[(i - 1) % #offsets + 1]
    all_ok = run_cycle('c' .. i, offset, #lines) and all_ok

    if i % 4 == 0 then
        mdmath.disable(bufnr)
        mdmath.enable(bufnr)
        print(string.format('cycle %d: disable/enable done', i))
    end
end

if #errors > 0 then
    print('\nerrors:')
    for _, err in ipairs(errors) do
        print('  ' .. err)
    end
end

print('\nRESULT: ' .. (all_ok and 'stable' or 'MISMATCH'))
mdmath.disable(bufnr)
