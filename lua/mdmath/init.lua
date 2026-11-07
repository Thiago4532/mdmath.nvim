local api = vim.api

local M = {}

M.version = require'mdmath.version'
M.is_loaded = false

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

function M.enable(bufnr)
    if not M.is_loaded then
        M.setup(false)
    end
    require 'mdmath.overlay'.enable(bufnr or 0)
end

function M.disable(bufnr)
    if not M.is_loaded then
        M.setup(false)
    end
    require 'mdmath.overlay'.disable(bufnr or 0)
end

function M.clear(bufnr)
    if not M.is_loaded then
        M.setup(false)
    end
    require 'mdmath.overlay'.clear(bufnr or 0)
end

function M.build()
    require'mdmath.build'.build()
end

return M
