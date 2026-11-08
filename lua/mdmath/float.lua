-- Floating-window renderer.
--
-- The overlay engine puts placeholder cells in the source buffer through
-- extmarks. A floating preview cannot do that: the cells have to live in a
-- scratch buffer whose whole content is the image, with the image id as the
-- foreground colour of every cell.
--
-- Lifecycle: a preview is anchored to the cursor, so any cursor movement,
-- scroll, insert-mode entry or buffer/window switch closes it. A newer request
-- also cancels an older one through the generation counter, including requests
-- that are still being rendered by node.

local api = vim.api
local util = require'mdmath.util'

local M = {}

local ns = api.nvim_create_namespace('mdmath-float')

---@class mdmath.FloatOpts : mdmath.RenderOpts
---@field border string|nil window border; default 'rounded'
---@field title string|nil window title

---@alias mdmath.FloatCallback fun(win: integer|nil, err: string|nil)

local state = {
    generation = 0,
    win = nil,
    buf = nil,
    image = nil,
}

local function teardown()
    -- Detach the handles before closing: `WinClosed` fires synchronously inside
    -- `nvim_win_close`, and the handler must not think a live preview was
    -- closed by the user (that would bump the generation and drop the request
    -- that is replacing it).
    local win, buf = state.win, state.buf
    state.win = nil
    state.buf = nil

    if state.image then
        state.image:close()
        state.image = nil
    end
    if win and api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true)
    end
    if buf and api.nvim_buf_is_valid(buf) then
        api.nvim_buf_delete(buf, {force = true})
    end
end

--- Closes the current preview. Idempotent.
function M.close()
    state.generation = state.generation + 1
    teardown()
end

--- Window id of the open preview, if any.
---@return integer|nil
function M.win()
    if state.win and api.nvim_win_is_valid(state.win) then
        return state.win
    end
    return nil
end

--- Builds the scratch buffer and the floating window for one image.
---@param image mdmath.Image
---@param opts mdmath.FloatOpts
---@return integer win
local function show(image, opts)
    local lines = image:text()

    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    -- The placeholder cells resolve to the image only when their foreground
    -- colour is the image id, the same rule the inline marks follow.
    local group = require'mdmath.highlight-colors'[image:color()]
    for i, line in ipairs(lines) do
        api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
            end_row = i - 1,
            end_col = #line,
            hl_group = group,
        })
    end

    -- Editing the cells would desynchronise them from the placement.
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = 'wipe'

    local win = api.nvim_open_win(buf, false, {
        relative = 'cursor',
        row = 1,
        col = 0,
        width = image.cols,
        height = image.rows,
        style = 'minimal',
        border = opts.border or 'rounded',
        title = opts.title,
        focusable = false,
    })

    state.buf = buf
    state.win = win
    state.image = image
    return win
end

--- Finds the `latex_block` under the cursor and returns its TeX source.
---@param bufnr integer|nil
---@return string|nil
function M.equation_under_cursor(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'markdown')
    if not ok or not parser then
        return nil
    end

    -- Without a range Neovim 0.12 does not process injections at all.
    parser:parse({0, api.nvim_buf_line_count(bufnr)})
    local inlines = parser:children()['markdown_inline']
    if not inlines then
        return nil
    end

    local cursor = api.nvim_win_get_cursor(0)
    local row, col = cursor[1] - 1, cursor[2]

    local query = vim.treesitter.query.parse('markdown_inline', '(latex_block) @block')
    local found
    inlines:for_each_tree(function(tree)
        if found then
            return
        end
        for _, node in query:iter_captures(tree:root(), bufnr) do
            local sr, sc, er, ec = node:range()
            local starts_before = row > sr or (row == sr and col >= sc)
            local ends_after = row < er or (row == er and col < ec)
            if starts_before and ends_after then
                found = vim.treesitter.get_node_text(node, bufnr)
                return
            end
        end
    end)

    if not found then
        return nil
    end
    -- Same stripping as `Equation`: the renderer gets the TeX, not the fences.
    return (found:gsub('^%$*(.-)%$*$', '%1'))
end

--- Opens (or replaces) the floating preview.
---
--- `tex` nil means "the equation under the cursor". The callback receives the
--- window id on success, or nil plus a message when the renderer fails.
---@param tex string|nil
---@param opts mdmath.FloatOpts|nil
---@param callback mdmath.FloatCallback|nil
function M.preview(tex, opts, callback)
    opts = opts or {}
    callback = callback or function(_, err)
        if err then
            util.err_message(err)
        end
    end

    if tex == nil then
        tex = M.equation_under_cursor(opts.bufnr)
        if not tex then
            return vim.schedule(function()
                callback(nil, 'no equation under the cursor')
            end)
        end
    end

    -- Bumped before rendering: a callback that arrives after the user moved on
    -- must drop its image instead of opening a stale window.
    local generation = state.generation + 1
    state.generation = generation
    teardown()

    require'mdmath.api'.render(tex, opts, function(image, err)
        if generation ~= state.generation then
            if image then
                image:close()
            end
            return
        end

        if not image then
            return callback(nil, err or 'render failed')
        end

        local ok, win_or_err = pcall(show, image, opts)
        if not ok then
            image:close()
            return callback(nil, tostring(win_or_err))
        end
        callback(win_or_err, nil)
    end)
end

local group = api.nvim_create_augroup('MdMathPreview', {clear = true})

api.nvim_create_autocmd({'CursorMoved', 'InsertEnter', 'BufLeave', 'WinLeave', 'WinScrolled'}, {
    group = group,
    callback = function()
        if state.win then
            M.close()
        end
    end,
})

api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
        if state.win and tonumber(args.match) == state.win then
            M.close()
        end
    end,
})

return M
