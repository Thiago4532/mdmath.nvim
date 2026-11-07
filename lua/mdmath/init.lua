local api = vim.api

--- Public module entry point.
---@class mdmath
---@field version string
---@field is_loaded boolean
local M = {}

M.version = require'mdmath.version'
M.is_loaded = false

--- Enables the plugin and registers the `FileType` autocmd. Calling it again
--- only errors when options are passed a second time.
---@param opts mdmath.Opts|false|nil
function M.setup(opts)
    if M.is_loaded then
        if opts then
            error("Attempt to setup mdmath.nvim multiple times (see README for more information)")
        end
        return
    end

    local filetypes = opts
        and opts.filetypes
        or {'markdown'}

    assert(type(filetypes) == 'table', 'filetypes: expected table, got ' .. type(filetypes))

    -- empty case: {}
    if filetypes[1] ~= nil then
        local group = api.nvim_create_augroup('MdMath', {clear = true})

        api.nvim_create_autocmd('FileType', {
            group = group,
            pattern = filetypes,
            callback = function()
                local bufnr = api.nvim_get_current_buf()

                -- defer the function, since it's not needed for the UI
                vim.defer_fn(function()
                    if api.nvim_buf_is_valid(bufnr) then
                        M.enable(bufnr)
                    end
                end, 100)
            end,
        })
    end

    require'mdmath.config'.set_opts(opts)
    M.is_loaded = true

    if opts ~= false then
        local filetype = vim.bo.filetype
        if filetype and vim.tbl_contains(filetypes, filetype) then
            M.enable()
        end
    end
end

---@param bufnr integer|nil defaults to the current buffer
function M.enable(bufnr)
    if not M.is_loaded then
        M.setup(false)
    end
    require 'mdmath.overlay'.enable(bufnr or 0)
end

---@param bufnr integer|nil defaults to the current buffer
function M.disable(bufnr)
    if not M.is_loaded then
        M.setup(false)
    end
    require 'mdmath.overlay'.disable(bufnr or 0)
end

--- Re-renders every equation of the buffer.
---@param bufnr integer|nil defaults to the current buffer
function M.clear(bufnr)
    if not M.is_loaded then
        M.setup(false)
    end
    require 'mdmath.overlay'.clear(bufnr or 0)
end

--- Installs the node.js renderer dependencies (`npm install`).
function M.build()
    require'mdmath.build'.build()
end

return M
