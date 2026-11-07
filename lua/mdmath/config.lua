--- Plugin options. Every field is filled in by `config.set_opts()`.
---@class mdmath.Opts
---@field filetypes string[]
---@field foreground string
---@field anticonceal boolean
---@field hide_on_insert boolean
---@field dynamic boolean
---@field dynamic_scale number
---@field internal_scale number
---@field update_interval integer
---@field transfer 'auto'|'file'|'direct'

---@type mdmath.Opts
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

    -- How the rendered PNG reaches the terminal:
    --   'auto'   -> 'file' (recommended)
    --   'file'   -> the terminal reads the PNG from disk (Kitty protocol `t=f`)
    --   'direct' -> the PNG is base64-chunked over stdout (`t=d`); only for
    --               terminals that cannot read a file path. Large writes can be
    --               split by Neovim's own redraws, which corrupts the escape
    --               sequence and prints the payload as text.
    transfer = 'auto',
}

---@type mdmath.Opts|nil
local _opts = nil
-- The read-only proxy handed out by `M.opts`. Kept in a local instead of a field
-- on `M`: a table field would be writable (`config.opts = {}` bypasses
-- `__newindex`, which only fires for missing keys).
---@type mdmath.Opts|nil
local readonly_opts = nil

--- Module table of the configuration singleton. `opts` is served through the
--- metatable below, so it is absent from the underlying table.
---@class mdmath.config
---@field opts mdmath.Opts
---@field validated boolean
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
        -- `validate()` installs the read-only proxy: return that instead of the
        -- writable table, otherwise the first accessor gets a mutable reference.
        return readonly_opts
    end,
    __newindex = function()
        error 'Attempt to modify read-only mdmath.nvim configuration.'
    end,
}

--- Type-checks and freezes the options. Called on the first `opts` access.
function M.validate()
    if M.validated then
        return
    end
    if _opts == nil then
        error "Attempt to validate mdmath.nvim before configuring it."
    end
    local opts = _opts

    vim.validate {
        filetypes = {opts.filetypes, 'table'},
        foreground = {opts.foreground, 'string'},
        anticonceal = {opts.anticonceal, 'boolean'},
        hide_on_insert = {opts.hide_on_insert, 'boolean'},
        dynamic = {opts.dynamic, 'boolean'},
        dynamic_scale = {opts.dynamic_scale, 'number'},
        internal_scale = {opts.internal_scale, 'number'},
        update_interval = {opts.update_interval, 'number'},
        transfer = {opts.transfer, 'string'},
    }

    -- Both scales are divisors in the renderer: zero or negative values would
    -- produce empty/invalid images.
    assert(opts.dynamic_scale > 0, 'mdmath.nvim: `dynamic_scale` must be greater than 0')
    assert(opts.internal_scale > 0, 'mdmath.nvim: `internal_scale` must be greater than 0')
    assert(opts.update_interval >= 0, 'mdmath.nvim: `update_interval` must not be negative')
    assert(vim.tbl_contains({'auto', 'file', 'direct'}, opts.transfer),
        'mdmath.nvim: `transfer` must be one of "auto", "file", "direct"')

    opts.foreground = require'mdmath.util'.hl_as_hex(opts.foreground)

    -- A plain `__newindex` is not enough: it is only called for missing keys, so
    -- writes to existing options would silently go through. Expose a proxy instead.
    local readonly = setmetatable({}, {
        __index = opts,
        __newindex = function()
            error 'Attempt to modify read-only mdmath.nvim options.'
        end,
        __pairs = function()
            return pairs(opts)
        end,
        __metatable = false,
    })

    -- The option is not part of `mdmath.Opts`: it was removed, and reading it is
    -- only there to warn users of the old spelling.
    ---@diagnostic disable-next-line: undefined-field
    if opts.scale then
        vim.schedule(function()
            vim.notify('mdmath.nvim: `scale` option was removed, check `dynamic_scale` and `internal_scale`.', vim.log.levels.WARN)
        end)
    end

    M.validated = true
    readonly_opts = readonly
end

--- Stores the user options merged over the defaults. Only valid once.
---@param opts mdmath.Opts|false|nil
function M.set_opts(opts)
    if _opts then
        error 'Attempt to configure mdmath.nvim opts multiple times (how did you even do that?)'
    end

    _opts = vim.tbl_extend('force', default_opts, opts or {})
end

setmetatable(M, mt)
return M
