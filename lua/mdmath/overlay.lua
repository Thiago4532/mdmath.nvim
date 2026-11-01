local nvim = require'mdmath.nvim'
local util = require'mdmath.util'
local ts = vim.treesitter
local uv = vim.uv
local Equation = require'mdmath.Equation'
local config = require'mdmath.config'.opts

local augroup = nvim.create_augroup('MdMathManager', {clear = true})

local M = {}
local buffers = {}

local Buffer = util.class 'Buffer'

local INLINE_LANG = 'markdown_inline'
local inline_query = nil

-- Compiling the query on every parse tick is wasteful; it only depends on the
-- language, never on the buffer.
local function get_inline_query()
    if not inline_query then
        inline_query = vim.treesitter.query.parse(INLINE_LANG, '(latex_block) @block')
    end
    return inline_query
end

-- FIX: Temporary workaround before NeoVim 0.12
local function get_parser(bufnr, lang)
    local parser = ts.get_parser(bufnr, lang)
    if not parser then
        error('Parser not found for ' .. lang, 2)
    end

    return parser
end

function Buffer:_init(bufnr)
    self.bufnr = bufnr
    self.equations = {}
    self.parser = get_parser(bufnr, 'markdown')
    self.active = true
    self.timer = uv.new_timer()
    assert(self.timer, 'failed to create a timer')

    self:attach()

    nvim.create_autocmd({'InsertLeave'}, {
        buffer = bufnr,
        group = augroup,
        callback = function()
            self:parse_view()
        end
    })
    nvim.create_autocmd({'WinScrolled'}, {
        buffer = bufnr,
        group = augroup,
        callback = function()
            self:reset_timer()
        end
    })

    self:parse_view()
end

function Buffer:clear(reset)
    for _, eq in ipairs(self.equations) do
        eq:invalidate()
    end
    self.equations = {}

    if reset then
        self:reset_timer()
    end
end

function Buffer:free()
    if not self.active then
        return
    end
    self.active = false
    buffers[self.bufnr] = nil

    self.timer:stop()
    self.timer:close()

    self:clear(false)

    nvim.clear_autocmds {
        group = augroup,
        buffer = self.bufnr
    }
end

function Buffer:reset_timer()
    self.timer:start(config.update_interval, 0, vim.schedule_wrap(function()
        return self:parse_view()
    end))
end

function Buffer:attach()
    nvim.buf_attach(self.bufnr, false, {
        on_lines = function()
            if not self.active then
                return true
            end
            self:reset_timer()
        end,
        on_detach = function()
            self:free()
        end
    })
end

function Buffer:parse_view()
    local start_row, end_row = util.get_current_view()
    self:parse(start_row, end_row)
end

function Buffer:parse(start_row, end_row)
    assert(type(start_row) == 'number', 'start_row must be a number')
    assert(type(end_row) == 'number', 'end_row must be a number')

    local bufnr = self.bufnr
    local parser = self.parser
    parser:parse({start_row, end_row})

    local inlines = parser:children()[INLINE_LANG]
    if not inlines then
        return nil
    end
    local query = get_inline_query()

    local old_equations = self.equations
    local equations = {}

    local function process_equation(sr, sc, er, ec, text)
        -- FIXME: Iterating over all equations is not efficient, we can use a hash table
        local equation = nil
        for key, eq in ipairs(old_equations) do
            if eq ~= 0 and eq.valid and eq.pos[1] == sr and eq.pos[2] == sc and eq.text == text then
                equation = eq
                old_equations[key] = 0
                break
            end
        end

        equation = equation or Equation.new(bufnr, sr, sc, text)
        if equation then
            table.insert(equations, equation)
        end
    end

    local function get_queries(tree)
        local root = tree:root()
        local tsr, _, ter = root:range()

        -- Each injected `markdown_inline` tree covers one markdown block, so
        -- rejecting the trees that cannot overlap the viewport is far cheaper than
        -- running the query over the whole document on every tick. Unlike passing
        -- the viewport to `iter_captures` (which filters by capture *start* row),
        -- this still sees a block that begins above the viewport and ends inside.
        if ter < start_row or tsr >= end_row then
            return
        end

        for _, node in query:iter_captures(root, bufnr) do
            local sr, sc, er, ec = node:range()
            if er >= start_row and sr < end_row then
                local value = ts.get_node_text(node, bufnr)
                process_equation(sr, sc, er, ec, value)
            end
        end
    end
    inlines:for_each_tree(get_queries)

    for _, eq in ipairs(old_equations) do
        if eq ~= 0 and eq.valid then
            if (not eq.pos[1] or (start_row <= eq.pos[1] and eq.pos[1] < end_row)) then
                eq:invalidate()
            else
                -- add equations out of the range
                table.insert(equations, eq)
            end
        end
    end

    self.equations = equations
end

local function create_buffer(bufnr)
    if not nvim.buf_is_valid(bufnr) then
        return nil
    end

    local buf = Buffer.new(bufnr)
    buffers[bufnr] = buf
    return buf
end

function M.enable(bufnr)
    if bufnr == 0 then
        bufnr = nvim.get_current_buf()
    end
    if buffers[bufnr] then
        return
    end

    if not create_buffer(bufnr) then
        error('Invalid buffer: ' .. bufnr)
    end
end

function M.disable(bufnr)
    if bufnr == 0 then
        bufnr = nvim.get_current_buf()
    end
    local buffer = buffers[bufnr]
    if buffer then
        buffer:free()
    end
end

function M.disable_all()
    for _, buffer in pairs(buffers) do
        buffer:free()
    end
end

function M.clear(bufnr)
    if bufnr == 0 then
        bufnr = nvim.get_current_buf()
    end
    local buffer = buffers[bufnr]
    if buffer then
        buffer:clear(true)
    end
end

-- `VimLeave` is not buffer-local. Registering it per buffer would leak one
-- callback for every enabled buffer, so keep a single global one.
nvim.create_autocmd({'VimLeave'}, {
    group = augroup,
    callback = function()
        M.disable_all()
    end,
})

return M
