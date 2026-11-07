-- TODO: This code needs to be basically rewritten. It's a mess.

local vim = vim
local util = require'mdmath.util'
local hl = require'mdmath.highlight-colors'
local tracker = require'mdmath.tracker'
local nvim = require'mdmath.nvim'
local config = require'mdmath.config'.opts

local ns = nvim.create_namespace('mdmath-marks')

--- A `{ text, byte length }` pair. A negative length marks a virtual line that
--- only exists in the rendered image.
---@class mdmath.mark.Text
---@field [1] string
---@field [2] integer

--- Options accepted by `marks.add`.
---@class mdmath.MarkOpts
---@field text mdmath.mark.Text|nil
---@field lines mdmath.mark.Text[]|nil
---@field color string|integer
---@field text_pos 'eol'|'overlay'|nil

--- An extmark group: the placeholder cells (or the error text) of one equation.
---@class mdmath.Mark
---@field bufnr integer
---@field opts mdmath.MarkOpts
---@field visible boolean
---@field render_visible boolean
---@field extmark_ids integer[]
---@field total_lines integer|nil
---@field lengths integer[]
---@field num_lines integer
---@field pos mdmath.Position
---@field id integer|nil
---@field _init fun(self: mdmath.Mark, bufnr: integer, row: integer, col: integer, opts: mdmath.MarkOpts): false|nil
---@field new fun(bufnr: integer, row: integer, col: integer, opts: mdmath.MarkOpts): mdmath.Mark?
local Mark = util.class 'Mark'
---@type table<integer, mdmath.marks.Buffer>
local buffers = {}
local num_buffers = 0

function Mark:_init(bufnr, row, col, opts)
    self.bufnr = bufnr
    self.opts = opts
    self.visible = false
    self.extmark_ids = {}
    self.render_visible = false

    -- FIX: Currently, lines that are smaller than the current line doesn't override the
    --      text below it. Although this is not intended, I don't think it's worth fixing it now.
    if opts.lines then
        self.total_lines = #opts.lines

        self.lengths = {}
        for _, line in ipairs(opts.lines) do
            local length = line[2]
            if length >= 0 then
                table.insert(self.lengths, length)
            end
        end
        self.num_lines = #self.lengths
    else
        self.num_lines = 1
        self.lengths = { opts.text[2] }
    end

    local row_end, col_end
    if self.num_lines > 1 then
        row_end = row + self.num_lines - 1
        col_end = self.lengths[self.num_lines]
    else
        row_end = row
        col_end = col + self.lengths[1]
    end

    local pos = tracker.add(bufnr, row, col, row_end, col_end)
    if not pos then
        -- Buffer is not tracked (e.g. `buf_attach` failed), the mark cannot be
        -- repositioned so there is no point in keeping it.
        return false
    end
    self.pos = pos

    self.pos.on_finish = function()
        self:remove()
    end
end

function Mark:remove()
    local buffer = rawget(buffers, self.bufnr)
    if not buffer then
        return
    end
    buffer:remove(self.id)
end

---@param row integer 0-indexed
---@param col integer 0-indexed
---@return boolean
function Mark:contains(row, col)
    local srow, scol = unpack(self.pos)
    if self.num_lines == 1 then
        return srow == row and scol <= col and col < scol + self.lengths[1]
    end

    if row < srow or row >= srow + self.num_lines then
        return false
    end

    if row == srow then
        return col >= scol
    end

    if row == srow + self.num_lines - 1 then
        return col < self.lengths[self.num_lines]
    end

    return true
end

---@param visible boolean
function Mark:set_visible(visible)
    if self.visible == visible then
        return
    end

    self.visible = visible
end

--- Per-buffer registry of marks, plus the `_show` switch used by `hide_on_insert`.
---@class mdmath.marks.Buffer
---@field bufnr integer
---@field marks table<integer, mdmath.Mark>
---@field _show boolean
---@field _init fun(self: mdmath.marks.Buffer, bufnr: integer)
---@field new fun(bufnr: integer): mdmath.marks.Buffer
local Buffer = util.class 'Buffer'

function Buffer:_init(bufnr)
    self.bufnr = bufnr
    self.marks = {}
    self._show = true
end

--- Forces a redraw so the decoration provider runs again.
function Buffer:redraw()
    nvim._redraw({
        buf = self.bufnr,
        valid = false,
    })
end

---@param mark mdmath.Mark
---@return integer id
function Buffer:add(mark)
    assert(mark.bufnr == self.bufnr)

    local id = #self.marks + 1
    mark.id = id
    self.marks[id] = mark

    mark:set_visible(true)
    return id
end

---@param id integer
function Buffer:remove(id)
    local mark = self.marks[id]
    if mark then
        for _, id in ipairs(mark.extmark_ids) do
            nvim.buf_del_extmark(self.bufnr, ns, id)
        end
        mark.extmark_ids = {}

        mark.visible = false
        mark.render_visible = false

        mark.pos:cancel()
        self.marks[id] = nil
    end
end

---@param show boolean
function Buffer:show(show)
    if self._show == show then
        return
    end

    assert(type(show) == 'boolean')
    self._show = show
    self:redraw()

    -- local bufnr = self.bufnr
    -- if not show then
    --     -- forcefully hide all marks without modifying visibility
    --     nvim.buf_clear_namespace(bufnr, ns, 0, -1)
    --     for _, mark in pairs(self.marks) do
    --         mark.id = nil -- do not change visibility, only forcefully hide
    --     end
    -- else
    --     for _, mark in pairs(self.marks) do
    --         mark:flush() -- flush visibility
    --     end
    -- end
end

--- Removes every mark and its extmarks.
function Buffer:clear()
    -- Drop the extmarks as well, otherwise they stay attached to the buffer
    -- forever (only the Lua table holding their ids is discarded).
    for _, mark in pairs(self.marks) do
        for _, id in ipairs(mark.extmark_ids) do
            nvim.buf_del_extmark(self.bufnr, ns, id)
        end
        mark.extmark_ids = {}
        mark.visible = false
        mark.render_visible = false
        if mark.pos then
            mark.pos:cancel()
        end
    end

    self.marks = {}
    self:redraw()
end

do
    ---@param opts {buf: integer}
    local function on_delete(opts)
        local bufnr = opts.buf
        if rawget(buffers, bufnr) ~= nil then
            buffers[bufnr] = nil
            num_buffers = num_buffers - 1
        end
    end

    ---@param opts {buf: integer}
    local function on_cursor(opts)
        if not config.anticonceal then
            return
        end
        local buffer = buffers[opts.buf]
        local row, col = util.get_cursor()

        for _, mark in pairs(buffer.marks) do
            local visible = not mark:contains(row, col)
            mark:set_visible(visible)
        end
    end

    ---@param opts {buf: integer}
    local function on_mode_change(opts)
        local buffer = buffers[opts.buf]
        ---@type table<string, string>
        local event = vim.v.event
        local old_mode = event.old_mode:sub(1, 1)
        local mode = event.new_mode:sub(1, 1)
        if old_mode == mode then
            return
        end

        if mode == 'n' then
            on_cursor(opts)
        end

        local hide = config.hide_on_insert and (mode == 'i' or mode == 'R')
        buffer:show(not hide)
    end

    setmetatable(buffers, {
        __index = function(_, bufnr)
            if bufnr == 0 then
                return buffers[nvim.get_current_buf()]
            end

            nvim.create_autocmd({'BufWipeout'}, {
                buffer = bufnr,
                callback = on_delete,
            })

            nvim.create_autocmd({'ModeChanged'}, {
                buffer = bufnr,
                callback = on_mode_change,
            })

            nvim.create_autocmd({'CursorMoved'}, {
                buffer = bufnr,
                callback = on_cursor,
            })

            local buf = Buffer.new(bufnr)
            buffers[bufnr] = buf
            num_buffers = num_buffers + 1
            return buf
        end,
    })
end

-- TODO: This can be done once instead of every redraw
---@param opts mdmath.MarkOpts
---@param row integer 0-indexed
---@param col integer 0-indexed
---@return table[] extmarks
---@return boolean multiline
local function opts2extmark(opts, row, col)
    if opts.lines then
        local extmarks = {}

        local is_last_virtual = false
        for _, line in ipairs(opts.lines) do
            local row_data = { { line[1], opts.color } }
            if line[2] < 0 then
                if not is_last_virtual then
                    local data = {
                        virt_lines = { row_data },
                        ephemeral = false,
                        undo_restore = false,
                    }
                    table.insert(extmarks, {
                        data = data,
                        row = row - 1,
                        col = col,
                    })
                else -- If the last line was virtual, just merge with it.
                    table.insert(extmarks[#extmarks].data.virt_lines, row_data)
                end
                is_last_virtual = true
            else
                local data = {
                    virt_text = row_data,
                    virt_text_pos = 'overlay',
                    ephemeral = false,
                    undo_restore = false,
                }
                table.insert(extmarks, {
                    data = data,
                    row = row,
                    col = col,
                })
                row = row + 1
                is_last_virtual = false
            end
            col = 0 -- reset col for next line
        end
        return extmarks, true
    else
        local data = {
            virt_text = { { opts.text[1], opts.color } },
            virt_text_pos = opts.text_pos,
            ephemeral = false,
            undo_restore = false,
        }
        return { {
            data = data,
            row = row,
            col = col
        } }, false
    end
end

---@param opts mdmath.MarkOpts
---@param row integer 0-indexed
---@return {row: integer, data: table}|nil
local function create_empty_virtual(opts, row)
    if not opts.lines then
        return nil
    end

    local virtual = 0
    for _, line in ipairs(opts.lines) do
        if line[2] >= 0 then
            row = row + 1
        else
            virtual = virtual + 1
        end
    end

    local lines = {}
    for i = 1, virtual do
        table.insert(lines, { { '', opts.color } })
    end

    local data = {
        virt_lines = lines,
        virt_lines_above = true,
        ephemeral = false,
        undo_restore = false,
    }

    return {
        row = row,
        data = data
    }
end

---@param visible boolean
function Mark:_draw(visible)
    local row, col = unpack(self.pos)

    for _, id in ipairs(self.extmark_ids) do
        nvim.buf_del_extmark(self.bufnr, ns, id)
    end
    self.extmark_ids = {}

    if not visible then
        local virtual = create_empty_virtual(self.opts, row)
        if virtual then
            local id = nvim.buf_set_extmark(self.bufnr, ns, virtual.row, 0, virtual.data)
            table.insert(self.extmark_ids, id)
        end
        return
    end

    local extmarks, lines = opts2extmark(self.opts, row, col)

    for i, extmark in ipairs(extmarks) do
        local id = nvim.buf_set_extmark(self.bufnr, ns, extmark.row, extmark.col, extmark.data)
        table.insert(self.extmark_ids, id)
    end
end

--- Re-draws the mark if its rendered state differs from the requested one.
---@param hidden boolean|nil hide without changing `visible`
---@return boolean redrawn
function Mark:flush(hidden)
    local visible = not hidden and self.visible
    if visible ~= self.render_visible then
        local ok, err = pcall(self._draw, self, visible)
        if not ok then
            vim.schedule(function()
                self:remove()
                nvim.err_writeln('mdmath: failed to draw mark: ' .. err)
            end)
        end
        self.render_visible = visible
        return true
    end
    return false
end

local M = {}

---@param bufnr integer 0 means the current buffer
---@param show boolean|nil
function M.show(bufnr, show)
    show = show == nil or show
    buffers[bufnr]:show(show)
end

--- Adds a mark over `(row, col)`; `opts.color` may be a raw 24-bit id.
---@param bufnr integer 0 means the current buffer
---@param row integer 0-indexed
---@param col integer 0-indexed
---@param opts mdmath.MarkOpts
---@return integer|nil id
function M.add(bufnr, row, col, opts)
    bufnr = bufnr == 0 and nvim.get_current_buf() or bufnr

    if type(opts.color) == 'number' then
        opts.color = hl[opts.color]
    end
    opts.text_pos = opts.text_pos or 'overlay'

    local mark = Mark.new(bufnr, row, col, opts)
    if not mark then
        return nil
    end
    return buffers[bufnr]:add(mark)
end

---@param bufnr integer|nil 0/nil means the current buffer
---@param id integer
function M.remove(bufnr, id)
    local buffer = rawget(buffers, bufnr)
    if buffer then
        buffer:remove(id)
    end
end

---@param bufnr integer|nil 0/nil means the current buffer
function M.clear(bufnr)
    bufnr = bufnr or nvim.get_current_buf()
    buffers[bufnr]:clear()
end

do
    nvim.set_decoration_provider(ns, {
        on_start = function()
            if num_buffers == 0 then
                return false
            end
        end,
        on_win = function(_, _, bufnr, top, bot)
            local buffer = rawget(buffers, bufnr)
            if not buffer then
                return false
            end
            top = top - 1

            for _, mark in pairs(buffer.marks) do
                local frow = mark.pos[1]
                if frow then
                    local lrow = frow + mark.num_lines - 1

                    if top <= lrow and frow <= bot then
                        mark:flush(not buffer._show)
                    end
                else
                    -- The tracked position was cancelled (buffer detached or a
                    -- tracker clear that did not go through `on_finish`). Drop the
                    -- mark instead of leaving it in the registry forever.
                    mark:remove()
                end
            end
            return false
        end,
    })
end

return M
