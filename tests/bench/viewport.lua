-- Quantifies the per-tick viewport scan.
--
-- The overlay used to run the latex query over every injected tree, because
-- passing the viewport to `iter_captures` filters by capture start row and drops
-- blocks that begin above the viewport. Skipping whole trees by their range is
-- equivalent and only pays for the trees that intersect the viewport.
--
-- Usage: nvim --headless --clean -l tests/bench/viewport.lua

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
vim.opt.rtp:prepend(root)

local tsrt = vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter/runtime')
if vim.uv.fs_stat(tsrt) then
    vim.opt.rtp:append(tsrt)
end

local PARAGRAPHS = tonumber(vim.env.MDMATH_BENCH_PARAGRAPHS) or 400
local ITERATIONS = tonumber(vim.env.MDMATH_BENCH_ITERATIONS) or 100
local VIEWPORT_ROWS = 40

local lines = {}
for i = 1, PARAGRAPHS do
    lines[#lines + 1] = ('Paragraph %d with $a_{%d} + b$ inline math.'):format(i, i)
    lines[#lines + 1] = ''
    lines[#lines + 1] = '$$'
    lines[#lines + 1] = ('x_{%d} = y + z'):format(i)
    lines[#lines + 1] = '$$'
    lines[#lines + 1] = ''
end

local bufnr = vim.api.nvim_create_buf(true, false)
vim.api.nvim_set_current_buf(bufnr)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
vim.bo[bufnr].filetype = 'markdown'

local parser = assert(vim.treesitter.get_parser(bufnr, 'markdown'))
parser:parse({ 0, #lines })

local inlines = parser:children()['markdown_inline']
if not inlines then
    print('markdown_inline injection is unavailable: install nvim-treesitter')
    os.exit(1)
end

local query = vim.treesitter.query.parse('markdown_inline', '(latex_block) @block')
local clock = vim.uv.hrtime

local function count_all()
    local n = 0
    inlines:for_each_tree(function(tree)
        for _ in query:iter_captures(tree:root(), bufnr) do
            n = n + 1
        end
    end)
    return n
end

local function count_viewport(start_row, end_row)
    local n = 0
    inlines:for_each_tree(function(tree)
        local sr, _, er = tree:root():range()
        if er < start_row or sr >= end_row then
            return
        end
        for _ in query:iter_captures(tree:root(), bufnr) do
            n = n + 1
        end
    end)
    return n
end

local function measure(fn)
    local start = clock()
    local last
    for _ = 1, ITERATIONS do
        last = fn()
    end
    return (clock() - start) / 1e6 / ITERATIONS, last
end

local full_ms, full_count = measure(count_all)
local view_ms, view_count = measure(function()
    return count_viewport(0, VIEWPORT_ROWS)
end)
local view_all_ms, view_all_count = measure(function()
    return count_viewport(0, #lines)
end)

print(('document: %d lines, %d equations'):format(#lines, full_count))
print(('full document scan:  %6.2f ms/tick (%d captures)'):format(full_ms, full_count))
print(('viewport scan:       %6.2f ms/tick (%d captures)'):format(view_ms, view_count))
print(('viewport=document:   %6.2f ms/tick (%d captures)'):format(view_all_ms, view_all_count))
print(('speedup on a %d-row viewport: %.1fx'):format(VIEWPORT_ROWS, full_ms / math.max(view_ms, 0.000001)))

assert(view_all_count == full_count, 'range-filtered scan must see every block when the viewport covers the document')
