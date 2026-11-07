local api = vim.api

local M = {}

local DEFAULT_CELL_WIDTH = 8
local DEFAULT_CELL_HEIGHT = 16

--- Terminal size in cells and pixels, as reported by `TIOCGWINSZ`.
---@class mdmath.Winsize
---@field row integer
---@field col integer
---@field xpixel integer
---@field ypixel integer

---@type mdmath.Winsize|nil
local winsize = nil
local warned_missing_pixels = false

--- Cached terminal size.
---@return mdmath.Winsize|nil
---@return integer|nil errno
function M.size()
    if winsize == nil then
        local size, err = require'mdmath.terminfo._system'.request_size()
        if not size then
            -- Not fatal: `cell_size()` falls back to a default. Happens when
            -- stdout is redirected (e.g. headless) and ioctl cannot be used.
            return nil, err
        end
        winsize = size
    end

    return winsize
end

--- Pixel size of a single cell, falling back to 8x16 when the terminal does not
--- report pixel dimensions.
---@return integer width
---@return integer height
function M.cell_size()
    local size, err = M.size()

    -- Most terminals report 0 for the pixel dimensions, which would make the
    -- renderer divide by zero. Fall back to a sane default and warn once.
    local width = size and size.col > 0 and size.xpixel / size.col or 0
    local height = size and size.row > 0 and size.ypixel / size.row or 0

    if width <= 0 or height <= 0 then
        width = DEFAULT_CELL_WIDTH
        height = DEFAULT_CELL_HEIGHT
        if not warned_missing_pixels then
            warned_missing_pixels = true
            local reason = size
                and 'the terminal does not report pixel dimensions'
                or ('cannot query the terminal size, errno ' .. tostring(err))
            vim.schedule(function()
                vim.notify('mdmath.nvim: ' .. reason .. ', '
                    .. 'assuming a cell size of ' .. width .. 'x' .. height .. 'px. '
                    .. 'Equations may look blurry or misaligned.', vim.log.levels.WARN)
            end)
        end
    end

    -- The protocol only accepts whole cells; a float would also break `%d`.
    return math.max(1, math.floor(width)), math.max(1, math.floor(height))
end

--- Drops the cached size so the next `size()` re-queries the terminal.
function M.refresh()
    winsize = nil
end

local function create_autocmd()
    api.nvim_create_autocmd('VimResized', {
        callback = function()
            M.refresh()
        end
    })
end

if vim.in_fast_event() then
    vim.schedule(create_autocmd)
else
    create_autocmd()
end

return M
