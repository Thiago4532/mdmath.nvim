-- Whether the terminal can display the plugin's images.
--
-- Rendering relies on Unicode placeholders (`U=1`): the image is pinned to text
-- cells, so it scrolls with the buffer and survives re-layout without any screen
-- bookkeeping. Terminals that implement the Kitty graphics protocol but not
-- placeholders cannot show it at all: the protocol only anchors *placements* to
-- the cursor cell, and a TUI cannot move the terminal cursor around without
-- corrupting its own output.
--
-- There is no capability query that works everywhere (Ghostty does not answer
-- feature queries), so known families are matched from TERM/TERM_PROGRAM and
-- anything unknown is treated as supported but not confirmed.

local M = {}

local KNOWN_UNSUPPORTED = {
    ['WezTerm'] = 'WezTerm implements the kitty graphics protocol but not Unicode placeholders (wezterm#7924)',
    ['Apple_Terminal'] = 'Terminal.app does not implement the kitty graphics protocol',
    ['vscode'] = 'the VS Code/Cursor terminal does not implement the kitty graphics protocol',
}

---@class mdmath.capability.Env
---@field TERM string|nil
---@field TERM_PROGRAM string|nil
---@field KITTY_WINDOW_ID string|nil

---@param env mdmath.capability.Env
---@return boolean supported
---@return string reason
---@return boolean confident
function M.classify(env)
    local term = (env.TERM or ''):lower()
    local program = env.TERM_PROGRAM or ''

    if env.KITTY_WINDOW_ID and env.KITTY_WINDOW_ID ~= '' then
        return true, 'kitty (KITTY_WINDOW_ID is set)', true
    end
    if term:find('kitty', 1, true) then
        return true, 'kitty (TERM=' .. term .. ')', true
    end
    if program == 'ghostty' or term:find('ghostty', 1, true) then
        return true, 'Ghostty (Unicode placeholders since 1.0)', true
    end

    if program == 'WezTerm' or term:find('wezterm', 1, true) then
        return false, KNOWN_UNSUPPORTED['WezTerm'], true
    end
    if term:find('konsole', 1, true) then
        return false, 'Konsole implements the kitty graphics protocol but not Unicode placeholders', true
    end
    if KNOWN_UNSUPPORTED[program] then
        return false, KNOWN_UNSUPPORTED[program], true
    end

    local name = program ~= '' and program or (env.TERM ~= '' and env.TERM or '<unset>')
    return true, 'unrecognised terminal (' .. name .. '), assuming Unicode placeholders work', false
end

---@return boolean supported
---@return string reason
---@return boolean confident
function M.supports_placeholders()
    if vim.g.mdmath_force_placeholders then
        return true, 'forced by vim.g.mdmath_force_placeholders', true
    end

    return M.classify({
        TERM = vim.env.TERM,
        TERM_PROGRAM = vim.env.TERM_PROGRAM,
        KITTY_WINDOW_ID = vim.env.KITTY_WINDOW_ID,
    })
end

return M
