-- Prints, for every visible equation mark in the current buffer, the number of
-- cells covered by the overlay versus the width of the source line it covers.
--
-- Usage: with mdmath enabled, put the cursor on a heading (so no equation is
-- concealed), then `:luafile tests/manual/dump-marks.lua`.
--
--   overlay < line  -> nvim shows raw text after the image (plugin/option bug)
--   overlay >= line -> the line is fully covered; leftovers on screen are a
--                      terminal repaint artifact, not a layout error

local ns = vim.api.nvim_get_namespaces()['mdmath-marks']
assert(ns, 'mdmath-marks namespace not found: is the plugin enabled?')

local buf = vim.api.nvim_get_current_buf()
local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {details = true})

local visible = {}
local concealed = {}

for _, m in ipairs(marks) do
    local row, details = m[2], m[4] or {}
    local virt_text = details.virt_text
    if virt_text and virt_text[1] then
        visible[#visible + 1] = {
            row = row,
            overlay = vim.fn.strdisplaywidth(virt_text[1][1]),
        }
    else
        concealed[#concealed + 1] = {
            row = row,
            lines = #(details.virt_lines or {}),
        }
    end
end

table.sort(visible, function(a, b)
    return a.row < b.row
end)

local problems = 0
for _, entry in ipairs(visible) do
    local line = vim.api.nvim_buf_get_lines(buf, entry.row, entry.row + 1, false)[1] or ''
    local width = vim.fn.strdisplaywidth(line)
    local covered = entry.overlay >= width
    if not covered then
        problems = problems + 1
    end
    print(string.format('row %3d  overlay %3d  line %3d  %s',
        entry.row, entry.overlay, width, covered and 'covered' or 'TAIL VISIBLE'))
end

print(string.format('\nvisible=%d concealed=%d problems=%d', #visible, #concealed, problems))

if #concealed > 0 then
    local rows = {}
    for _, entry in ipairs(concealed) do
        rows[#rows + 1] = string.format('%d(virt_lines=%d)', entry.row, entry.lines)
    end
    print('concealed rows: ' .. table.concat(rows, ' '))
    print('(virt_lines>0 are the extra rows of images taller than the source block;'
        .. ' virt_lines=0 means a block hidden because the cursor is inside it)')
end

print(string.format('wrap=%s smoothscroll=%s termguicolors=%s',
    tostring(vim.wo.wrap), tostring(vim.o.smoothscroll), tostring(vim.o.termguicolors)))
