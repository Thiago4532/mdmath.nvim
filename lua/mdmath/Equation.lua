local vim = vim
local nvim = require'mdmath.nvim'
local uv = vim.loop
local marks = require'mdmath.marks'
local util = require'mdmath.util'
local Processor = require'mdmath.Processor'
local Image = require'mdmath.Image'
local tracker = require'mdmath.tracker'
local terminfo = require'mdmath.terminfo'
local config = require'mdmath.config'.opts

---@class mdmath.EquationOpts
---@field color string|nil

--- One rendered (or pending) equation of a buffer.
---@class mdmath.Equation
---@field bufnr integer
---@field pos mdmath.Position tracked source range, kept in sync with edits
---@field text string source text as captured by the query
---@field equation string `text` without the surrounding `$`
---@field color string `#rrggbb`
---@field width integer display width in cells
---@field lines string[]|nil source lines for block equations
---@field lines_width integer[]|nil display width of each source line
---@field valid boolean false once invalidated; late callbacks are dropped
---@field created boolean whether a mark was actually added
---@field mark_id integer|nil
---@field image mdmath.Image|nil
---@field _init fun(self: mdmath.Equation, bufnr: integer, row: integer, col: integer, text: string, opts: mdmath.EquationOpts|nil): false|nil
---@field new fun(bufnr: integer, row: integer, col: integer, text: string, opts: mdmath.EquationOpts|nil): mdmath.Equation?
local Equation = util.class 'Equation'

function Equation:__tostring()
    return '<Equation>'
end

--- Turns a processor response into a mark (or an inline error message).
---@param res mdmath.Processor.Result|nil
---@param err string|nil
function Equation:_create(res, err)
    if not res then
        local text = ' ' .. err
        local color = 'Error'
        vim.schedule(function()
            if self.valid then
                self.mark_id = marks.add(self.bufnr, self.pos[1], self.pos[2], {
                    text = { text, self.text:len() },
                    color = color,
                    text_pos = 'eol',
                })
                self.created = true
            end
        end)
        return
    end

    local filename = res.data

    local width = res.width
    local height = res.height

    -- Multiline equations
    if self.lines then
        local image = Image.new(height, width, filename)
        if not image then
            -- Images cannot be displayed (e.g. stdout is not a TTY): keep the
            -- source text visible instead of writing broken placeholders.
            self:invalidate()
            return
        end

        local texts = image:text()
        local color = image:color()

        local nlines = #self.lines

        local lines = {}
        for i, text in ipairs(texts) do
            if i <= nlines then
                -- Increase text width to match the original width.
                local padding = self.lines_width[i] - width
                local rtext = padding > 0
                    and text .. (' '):rep(padding)
                    or text

                lines[i] = { rtext, self.lines[i]:len() }
            else
                -- add virtual lines
                lines[i] = { text, -1 }
            end
        end

        for i = #texts + 1, nlines do
            local padding = self.lines_width[i]
            lines[i] = { (' '):rep(padding), self.lines[i]:len() }
        end

        vim.schedule(function()
            if self.valid then
                self.mark_id = marks.add(self.bufnr, self.pos[1], self.pos[2], {
                    lines = lines,
                    color = color,
                    text_pos = 'overlay',
                })
                self.image = image
                self.created = true
            else -- free resources
                image:close()
            end
        end)
    else
        local image = Image.new(height, width, filename)
        if not image then
            self:invalidate()
            return
        end

        local text = image:text()[1]
        local color = image:color()

        vim.schedule(function()
            if self.valid then
                self.mark_id = marks.add(self.bufnr, self.pos[1], self.pos[2], {
                    text = { text, self.text:len() },
                    color = color,
                    text_pos = 'overlay',
                })
                self.image = image
                self.created = true
            else -- free resources
                image:close()
            end
        end)
    end
end

---@return false|nil false when the equation cannot be tracked or is malformed
function Equation:_init(bufnr, row, col, text, opts)
    local color = opts and opts.color or config.foreground

    if text:find('\n') then
        local lines = vim.split(text, '\n')
        -- Only support rectangular equations
        if util.linewidth(bufnr, row) ~= lines[1]:len() or util.linewidth(bufnr, row + #lines - 1) ~= lines[#lines]:len() then
            return false
        end

        local width = 0
        local lines_width = {}
        for i, line in ipairs(lines) do
            local w = util.strwidth(line)
            width = math.max(width, w)
            lines_width[i] = w
        end
        self.lines = lines
        self.lines_width = lines_width
        self.width = width
    elseif util.linewidth(bufnr, row) == text:len() then
        -- Treat single line equations as a special case
        self.width = util.strwidth(text)
        self.lines = { text }
        self.lines_width = { self.width }
    end

    self.bufnr = bufnr
    -- TODO: pos should be shared with the mark
    local pos = tracker.add(bufnr, row, col, text:len())
    if not pos then
        -- Buffer is not tracked (e.g. `buf_attach` failed), nothing to render.
        self.valid = false
        return false
    end
    self.pos = pos

    self.pos.on_finish = function()
        self:invalidate()
    end

    self.text = text
    if not self.lines then
        self.width = util.strwidth(text)
    end
    self.created = false
    self.valid = true
    self.color = color

    -- remove trailing '$'
    self.equation = text:gsub('^%$*(.-)%$*$', '%1')

    local cell_width, cell_height = terminfo.cell_size()

    local flags, height
    if self.lines then
        height = #self.lines
        if config.dynamic then
            flags = 1 -- dynamic
        else
            flags = 0
        end
    else
        height = 1
        flags = 2 -- centered
    end

    local processor = Processor.from_bufnr(bufnr)
    processor:request(self.equation, cell_width, cell_height, self.width, height, flags, color, function(res, err)
        if self.valid then
            self:_create(res, err)
        end
    end)
end

-- TODO: should we call invalidate() on '__gc'?
--- Cancels tracking and releases the mark and the image. Idempotent.
function Equation:invalidate()
    if not self.valid then
        return
    end
    self.valid = false

    -- Release the tracked position even when nothing was rendered yet, otherwise
    -- `tracker` keeps a stale entry until the buffer is wiped out.
    if self.pos then
        self.pos:cancel()
    end

    if not self.created then
        return
    end

    marks.remove(self.bufnr, self.mark_id)
    if self.image then
        self.image:close()
    end
    self.mark_id = nil
end

return Equation
