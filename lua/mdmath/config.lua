local default_opts = {
    -- Filetypes that the plugin will be enabled by default.
    filetypes = {'markdown'},
    -- Color of the equation, can be a highlight group or a hex color.
    -- Examples: 'Normal', '#ff0000'
    foreground = 'Normal',
    -- Hide the text when the equation is under the cursor.
    anticonceal = true,
    -- Hide the text when in the Insert Mode.
    hide_on_insert = true,
    -- Enable dynamic size for non-inline equations.
    dynamic = true,
    -- Configure the scale of dynamic-rendered equations.
    dynamic_scale = 1.0,
    -- Interval between updates (milliseconds).
    update_interval = 400,

    -- Internal scale of the equation images, increase to prevent blurry images when increasing terminal
    -- font, high values may produce aliased images.
    -- WARNING: This do not affect how the images are displayed, only how many pixels are used to render them.
    --          See `dynamic_scale` to modify the displayed size.
    internal_scale = 1.0,

    -- Commands that will be prepended to each equation
    -- Can be a string or function(filename) -> string
    preamble = "",
}

local _opts = nil

local M = {
    validated = false,
}

local mt = {
    __index = function(_, key)
        if key ~= 'opts' then
            return nil
        end

        if _opts == nil then
            error "Attempt to access mdmath.nvim options before configuring it. (Make sure to call `require'mdmath'.setup()` before using any module)"
        end

        M.validate()
        return _opts
    end,
    __newindex = function()
        error 'Attempt to modify read-only mdmath.nvim configuration.'
    end,
}

function M.validate()
    if M.validated then
        return
    end
    if _opts == nil then
        error "Attempt to validate mdmath.nvim before configuring it."
    end
    local opts = _opts

    vim.validate {
        foreground = {opts.foreground, 'string'},
        anticonceal = {opts.anticonceal, 'boolean'},
        hide_on_insert = {opts.hide_on_insert, 'boolean'},
        dynamic = {opts.dynamic, 'boolean'},
        dynamic_scale = {opts.dynamic_scale, 'number'},
        internal_scale = {opts.internal_scale, 'number'},
        preamble = {opts.preamble, {'string', 'function'}},
    }

    opts.foreground = require'mdmath.util'.hl_as_hex(opts.foreground)

    -- Validate preamble function signature if it's a function
    if type(opts.preamble) == "function" then
        local ok, result = pcall(opts.preamble, "")
        if not ok or type(result) ~= "string" then
            error("preamble function must accept a filename (string) and return a string")
        end
    end

    setmetatable(opts, {
        __newindex = function()
            error 'Attempt to modify read-only mdmath.nvim options.'
        end,
    })

    if opts.scale then
        vim.schedule(function()
            vim.notify('mdmath.nvim: `scale` option was removed, check `dynamic_scale` and `internal_scale`.', vim.log.levels.WARN)
        end)
    end

    M.validated = true
    rawset(M, 'opts', opts)
end

function M.set_opts(opts)
    if _opts then
        error 'Attempt to configure mdmath.nvim opts multiple times (how did you even do that?)'
    end

    _opts = vim.tbl_extend('force', default_opts, opts or {})
end

setmetatable(M, mt)
return M
