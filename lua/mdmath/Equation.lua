local vim = vim
local nvim = require'mdmath.nvim'
local uv = vim.loop
local marks = require'mdmath.marks'
local util = require'mdmath.util'
local Processor = require'mdmath.Processor'
local Image = require'mdmath.Image'
local tracker = require'mdmath.tracker'
local terminfo = require'mdmath.terminfo'

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

        -- Increase text width to match the original width
        local padding_len = self.width > width and self.width - width or 0
        local padding = (' '):rep(padding_len)

        local nlines = #self.lines

        local lines = {}
        for i, text in ipairs(texts) do
            local rtext = text .. padding

            -- add virtual lines
            local len = i <= nlines
                and self.lines[i]:len()
                or -1

            lines[i] = { rtext, len }
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

function Equation:_init(bufnr, row, col, text)
    if text:find('\n') then
        local lines = vim.split(text, '\n')
        -- Only support rectangular equations
        if util.linewidth(bufnr, row) ~= lines[1]:len() or util.linewidth(bufnr, row + #lines - 1) ~= lines[#lines]:len() then
            return false
        end

        local width = 0
        for i, line in ipairs(lines) do
            width = math.max(width, util.strwidth(line))
        end
        self.lines = lines
        self.width = width
    elseif util.linewidth(bufnr, row) == text:len() then
        -- Treat single line equations as a special case
        self.width = util.strwidth(text)
        self.lines = { text }
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
    
    -- remove trailing '$'
    self.equation = text:gsub('^%$*(.-)%$*$', '%1')

    local cell_width, cell_height = terminfo.cell_size()

    local flags, height
    if self.lines then
        height = #self.lines
        flags = 1 -- dynamic
    else
        height = 1
        flags = 2 -- centered
    end

    local processor = Processor.from_bufnr(bufnr)
    processor:request(self.equation, cell_width, cell_height, self.width, height, flags, function(res, err)
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
