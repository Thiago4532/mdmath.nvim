local vim = vim
local nvim = require'mdmath.nvim'

local M = {}

--- Creates a class table. The returned table is used as the class object: it
--- carries `new(...)`, and the instance metatable's `__index` points at it, so
--- methods are added with `function Class:method()` after creation.
---@generic T
---@param name string
---@return T
function M.class(name)
    local class = {}
    class.__index = class
    class.__name = name
    class.new = function(...)
        local self = setmetatable({}, class)
        if self._init then
            if self:_init(...) == false then
                return nil
            end
        end
        return self
    end
    return class
end

---@param winid integer|nil
---@return integer row 0-indexed
---@return integer col 0-indexed
function M.get_cursor(winid)
    local cursor = nvim.win_get_cursor(winid or 0)
    return cursor[1] - 1, cursor[2]
end

-- FIXME: Almost sure this can be made more efficient
---@param bufnr integer
---@param row integer 0-indexed
---@return integer
function M.linewidth(bufnr, row)
    local line = nvim.buf_get_lines(bufnr, row, row + 1, false)
    return line and line[1]:len() or 0
end

--- Byte offset of a (row, col) position inside the buffer.
---@param bufnr integer
---@param row integer 0-indexed
---@param col integer 0-indexed
---@return integer|nil nil when the row is out of range
function M.compute_offset(bufnr, row, col)
    local row_offset = nvim.buf_get_offset(bufnr, row)
    if row_offset == -1 then
        return nil
    end

    local len = M.linewidth(bufnr, row)

    local col_offset = len < col and len or col
    return row_offset + col_offset
end

--- Viewport of the current window.
---@return integer start_row 0-indexed, inclusive
---@return integer end_row 1-indexed, exclusive
function M.get_current_view()
    local a = vim.fn.line('w0')
    local b = vim.fn.line('w$')
    return a - 1, b
end

---@param str string
---@return integer
function M.strwidth(str)
    -- TODO: Is nvim.strwidth() the same thing?
    return vim.fn.strdisplaywidth(str)
end

---@param line integer 1-indexed
---@return integer
function M.linedisplaywidth(line)
    return vim.fn.col({line, '$'})
end

---@param ... string|number
function M.err_message(...)
    local message = table.concat(vim.iter({ ... }):flatten():totable())
    if vim.in_fast_event() then
        vim.schedule(function()
            vim.notify('mdmath.nvim: ' .. message, vim.log.levels.ERROR)
        end)
    else
        vim.notify('mdmath.nvim: ' .. message, vim.log.levels.ERROR)
    end
end

---@param color string
---@return boolean
function M.is_hex_color(color)
    return color:match('^#%x%x%x%x%x%x$') ~= nil
end

--- Resolves a hex colour or a highlight group name to `#rrggbb`.
---@param color string
---@return string
function M.hl_as_hex(color)
    if M.is_hex_color(color) then
        return color:lower()
    end

    local hl = nvim.get_hl(0, {name = color, create = false, link = false})
    if not hl or type(hl.fg) ~= 'number' then
        error(string.format('foreground: "%s" is neither a hex color nor a highlight group with a fg color', color))
    end

    return string.format('#%06x', hl.fg)
end

return M
