local nvim = require'mdmath.nvim'
local util = require'mdmath.util'

--- A tracked source range, updated from `on_bytes` events. Position is stored
--- as `(row, col)` plus a byte offset and length so edits above it can shift it
--- without recomputing from the buffer.
---@class mdmath.Position
---@field [1] integer row, 0-indexed
---@field [2] integer col, 0-indexed
---@field offset integer byte offset
---@field length integer byte length
---@field on_finish fun()|nil
---@field cancel fun(self: mdmath.Position)

---@class mdmath.tracker.Buffer
---@field bufnr integer
---@field attached boolean
---@field positions table<integer, mdmath.Position>

---@type table<integer, mdmath.tracker.Buffer>
local buffers = {}

---@param pos mdmath.Position
local function cancel_pos(pos)
    pos[1] = nil
    pos[2] = nil
    pos.offset = nil
    pos.length = nil
    pos.on_finish = nil
end

---@param pos mdmath.Position
local function clear_pos(pos)
    if pos.on_finish then
        pos.on_finish()
    end

    cancel_pos(pos)
end

--- Applies one `on_bytes` delta to a position.
---@param pos mdmath.Position
---@param sr integer start row of the change, 0-indexed
---@param sc integer start col of the change, 0-indexed
---@param soff integer start byte offset of the change
---@param oer integer old end row (absolute)
---@param oec integer old end col (absolute unless `oer == sr`)
---@param oeoff integer old end byte offset (absolute)
---@param er integer new end row (absolute)
---@param ec integer new end col (absolute unless `er == sr`)
---@param eoff integer new end byte offset (absolute)
local function update_pos(pos, sr, sc, soff, oer, oec, oeoff, er, ec, eoff)
    local offset = pos.offset
    local length = pos.length
    if offset + length <= soff then
        return
    end

    if offset < oeoff then
        -- UU.notify(nil, {'modified!')
        return clear_pos(pos)
    end

    offset = offset + eoff - oeoff

    local row, col = pos[1], pos[2]

    row = row + er - oer

    if row == er then
        col = col + ec - oec
    end

    pos[1] = row
    pos[2] = col
    pos.offset = offset
end

---@param buf mdmath.tracker.Buffer
---@return mdmath.tracker.Buffer|nil
local function attach(buf)
    if buf.attached then
        return buf
    end
    local bufnr = buf.bufnr

    local success = nvim.buf_attach(bufnr, false, {
        on_bytes = function(_, _, _, sr, sc, soff, oer, oec, oeoff, er, ec, eoff)
            -- Converting relative to absolute positions
            oer = oer + sr
            oec = oer == sr and oec + sc or oec
            er = er + sr
            ec = er == sr and ec + sc or ec
            oeoff = oeoff + soff
            eoff = eoff + soff

            local first = true
            for key, pos in pairs(buf.positions) do
                if pos[1] == nil then
                    buf.positions[key] = nil
                else
                    if first then
                        -- UU.notify('start', {sr + 1, sc + 1, soff}, 1444)
                        -- UU.notify('old', {oer + 1, oec + 1, oeoff}, 1443)
                        -- UU.notify('new', {er + 1, ec + 1, eoff}, 1442)
                        first = false
                    end
                    update_pos(pos, sr, sc, soff, oer, oec, oeoff, er, ec, eoff)
                end
            end
        end,
        on_detach = function()
            buf.attached = false
        end
    })
    if not success then
        return nil
    end
    buf.attached = true

    nvim.create_autocmd({'BufRead'}, {
        buffer = bufnr,
        callback = function()
            attach(buf)
        end
    })
    return buf
end

local weak_mt = { __mode = 'v' }

setmetatable(buffers, {
    __index = function(_, bufnr)
        if bufnr == 0 then
            return buffers[nvim.get_current_buf()]
        end

        local buf = attach {
            bufnr = bufnr,
            attached = false,
            positions = setmetatable({}, weak_mt),
        }
        if not buf then
            return nil
        end

        buffers[bufnr] = buf
        nvim.create_autocmd({'BufWipeout'}, {
            buffer = bufnr,
            callback = function()
                buffers[bufnr] = nil

                for _, pos in pairs(buf.positions) do
                    clear_pos(pos)
                end
            end
        })

        return buf
    end
})

local M = {}

--- Registers a position. Pass `row_end`/`col_end` for a multi-line range.
---@param bufnr integer 0 means the current buffer
---@param row integer 0-indexed
---@param col integer 0-indexed
---@param row_end integer|nil
---@param col_end integer|nil
---@return mdmath.Position|nil nil when the buffer cannot be tracked
function M.add(bufnr, row, col, row_end, col_end)
    local buffer = buffers[bufnr]
    if not buffer then
        return nil
    end

    local offset = util.compute_offset(bufnr, row, col)
    if not offset then
        return nil
    end

    local length
    if row_end == nil then
        length = 1
    elseif col_end == nil then
        length = row_end
    else
        assert(row_end >= row)
        if row_end == row then
            assert(col_end > col)
        end

        length = util.compute_offset(bufnr, row_end, col_end) - offset
    end

    local pos = {
        row, col,
        offset = offset,
        length = length,
        on_finish = nil,

        cancel = cancel_pos,
    }
    table.insert(buffer.positions, pos)

    return pos
end

return M
