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

local Equation = util.class 'Equation'

function Equation:__tostring()
    return '<Equation>'
end

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
    self.pos = tracker.add(bufnr, row, col, text:len())
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
    local preamble = type(config.preamble) == "function" and config.preamble(vim.api.nvim_buf_get_name(bufnr))
        or config.preamble
    local data = preamble .. self.equation
    processor:request(data, cell_width, cell_height, self.width, height, flags, color, function(res, err)
        if self.valid then
            self:_create(res, err)
        end
    end)
end

-- TODO: should we call invalidate() on '__gc'?
function Equation:invalidate()
    if not self.valid then
        return
    end
    self.valid = false
    if not self.created then
        return
    end

    self.pos:cancel()
    marks.remove(self.bufnr, self.mark_id)
    if self.image then
        self.image:close()
    end
    self.mark_id = nil
end

return Equation
