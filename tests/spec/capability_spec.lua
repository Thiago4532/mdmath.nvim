-- Terminal classification for Unicode placeholder support.
--
-- There is no capability query that every terminal answers, so the plugin keeps
-- a small list of known families and treats everything else as "supported, but
-- not confirmed". A wrong positive costs tofu glyphs; a wrong negative hides
-- images from a terminal that could show them.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local t = dofile(root .. '/tests/helper.lua')
t.bootstrap()

local capability = require'mdmath.capability'

local cases = {
    { name = 'kitty via KITTY_WINDOW_ID', env = { TERM = 'xterm-256color', KITTY_WINDOW_ID = '1' }, supported = true, confident = true },
    { name = 'kitty via TERM', env = { TERM = 'xterm-kitty' }, supported = true, confident = true },
    { name = 'ghostty via TERM_PROGRAM', env = { TERM = 'xterm-ghostty', TERM_PROGRAM = 'ghostty' }, supported = true, confident = true },
    { name = 'wezterm', env = { TERM = 'xterm-256color', TERM_PROGRAM = 'WezTerm' }, supported = false, confident = true },
    { name = 'wezterm via TERM', env = { TERM = 'wezterm' }, supported = false, confident = true },
    { name = 'konsole TERM', env = { TERM = 'konsole-256color' }, supported = false, confident = true },
    { name = 'apple terminal', env = { TERM = 'xterm-256color', TERM_PROGRAM = 'Apple_Terminal' }, supported = false, confident = true },
    { name = 'vs code', env = { TERM = 'xterm-256color', TERM_PROGRAM = 'vscode' }, supported = false, confident = true },
    { name = 'unknown', env = { TERM = 'xterm-256color' }, supported = true, confident = false },
    { name = 'nothing set', env = {}, supported = true, confident = false },
}

for _, case in ipairs(cases) do
    local supported, reason, confident = capability.classify(case.env)
    t.eq(supported, case.supported, case.name .. ' supported')
    t.eq(confident, case.confident, case.name .. ' confidence')
    t.ok(type(reason) == 'string' and reason ~= '', case.name .. ' has a reason')
end

t.finish()
