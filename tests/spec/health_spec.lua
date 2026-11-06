-- `:checkhealth mdmath` must produce a report without throwing, even when
-- dependencies are missing or the plugin was never set up (the health provider
-- runs in exactly those situations).

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local t = dofile(root .. '/tests/helper.lua')
t.bootstrap()

local ok, err = pcall(vim.cmd, 'checkhealth mdmath')
t.ok(ok, 'checkhealth mdmath runs (' .. tostring(err) .. ')')

local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
local text = table.concat(lines, '\n')

t.ok(text:find('mdmath%.nvim', 1) ~= nil, 'report mentions the plugin')
t.ok(text:find('mdmath%.nvim: parser', 1) ~= nil, 'report has a parser section')
t.ok(text:find('mdmath%.nvim: dependencies', 1) ~= nil, 'report has a dependencies section')
t.ok(text:find('mdmath%.nvim: configuration', 1) ~= nil, 'report has a configuration section')
t.ok(text:find('mdmath%.nvim: terminal', 1) ~= nil, 'report has a terminal section')

-- Errors are rendered by the health framework, so a broken provider would show
-- up as an "E5113" or a stack trace rather than as a missing section.
t.ok(text:find('E5113', 1) == nil, 'report contains no Lua error')

t.finish()
