-- Public rendering API: TeX in, `mdmath.Image` out.
--
-- A thin wrapper over `Processor` (TeX -> PNG over IPC) and `Image` (Kitty
-- transmission). There is deliberately no Lua-side cache: the node process
-- already deduplicates identical renders by content (same equation, cell size,
-- requested size, flags, colour and scales return the same PNG path), and a
-- Lua cache would go stale as soon as the shared processor exits and deletes
-- its temporary files.
--
-- Use `require'mdmath'.render` rather than requiring this module directly: it
-- also initialises the plugin on first use.

local M = {}

---@class mdmath.RenderOpts
---@field bufnr integer|nil buffer that owns the shared renderer; default: current buffer
---@field color string|nil `#rrggbb` or highlight group; default: `config.foreground`
---@field width integer|nil minimum width in cells; default 1
---@field height integer|nil minimum height in cells; default 1
---@field dynamic boolean|nil grow block equations to their natural size; default true
---@field center boolean|nil centre the image in its cells; default false
---@field cell_width integer|nil pixels per cell; default: queried from the terminal
---@field cell_height integer|nil pixels per cell; default: queried from the terminal

---@alias mdmath.RenderCallback fun(image: mdmath.Image|nil, err: string|nil)

--- Delivers a failure asynchronously, so callers only handle one ordering.
---@param callback mdmath.RenderCallback
---@param message string
local function fail(callback, message)
    vim.schedule(function()
        callback(nil, message)
    end)
end

--- Resolves the requested colour; returns nil plus the error on failure.
---@param color string|nil
---@return string|nil
---@return string|nil
local function resolve_color(color)
    local opts = require'mdmath.config'.opts
    local ok, resolved = pcall(require'mdmath.util'.hl_as_hex, color or opts.foreground)
    if not ok then
        return nil, resolved
    end
    return resolved
end

--- Renders TeX to a PNG and places it with a virtual Kitty placement.
---
--- The callback runs exactly once, always outside the libuv fast context:
--- `image` on success, `err` on failure. Argument misuse raises instead; a
--- renderer failure (invalid TeX, missing binary, no TTY) goes through `err`.
---
--- The image is addressed by its id, which doubles as the foreground colour of
--- the placeholder cells returned by `image:text()`. Call `image:close()` when
--- the cells are no longer displayed.
---@param tex string TeX source without the surrounding `$`
---@param opts mdmath.RenderOpts|nil
---@param callback mdmath.RenderCallback
function M.render(tex, opts, callback)
    assert(type(tex) == 'string', 'tex: expected string, got ' .. type(tex))
    assert(type(callback) == 'function', 'callback: expected function, got ' .. type(callback))

    opts = opts or {}
    if tex:match('^%s*$') then
        return fail(callback, 'empty equation')
    end

    local color, color_err = resolve_color(opts.color)
    if not color then
        return fail(callback, color_err or 'invalid colour')
    end

    local width = opts.width or 1
    local height = opts.height or 1
    assert(type(width) == 'number' and width >= 1, 'width: expected a number >= 1, got ' .. tostring(width))
    assert(type(height) == 'number' and height >= 1, 'height: expected a number >= 1, got ' .. tostring(height))

    local cell_width, cell_height = opts.cell_width, opts.cell_height
    if not (cell_width and cell_height) then
        local queried_width, queried_height = require'mdmath.terminfo'.cell_size()
        cell_width = cell_width or queried_width
        cell_height = cell_height or queried_height
    end

    local flags = 0
    if opts.dynamic ~= false then
        flags = flags + 1
    end
    if opts.center then
        flags = flags + 2
    end

    local ok_processor, processor_or_err = pcall(function()
        return require'mdmath.Processor'.from_bufnr(opts.bufnr or 0)
    end)
    if not ok_processor then
        return fail(callback, tostring(processor_or_err))
    end
    local processor = processor_or_err

    local ok_request, request_err = pcall(processor.request, processor,
        tex, cell_width, cell_height, width, height, flags, color,
        function(res, err)
            vim.schedule(function()
                if not res then
                    return callback(nil, err or 'render failed')
                end

                -- The renderer may have grown the image (dynamic sizing), so the
                -- placement must use the dimensions it reports, not the requested
                -- minimum.
                local image = require'mdmath.Image'.new(res.height, res.width, res.data)
                if not image then
                    return callback(nil, 'the terminal cannot display images (stdout is not a TTY)')
                end
                callback(image)
            end)
        end)

    if not ok_request then
        return fail(callback, tostring(request_err))
    end
end

return M
