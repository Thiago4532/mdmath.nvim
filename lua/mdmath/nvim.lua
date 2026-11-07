local api = vim.api

-- Lazily-bound proxy over `vim.api`: `nvim.buf_get_lines` resolves to
-- `vim.api.nvim_buf_get_lines` on first access and caches the function.
---@type table<string, fun(...): any>
local proxy = setmetatable({}, {
    __index = function(self, key)
        local s = api['nvim_' .. key]
        self[key] = s
        return s
    end
})

return proxy
