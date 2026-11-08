-- Floating-window renderer.
--
-- The overlay engine puts placeholder cells in the source buffer through
-- extmarks. A floating preview cannot do that: the cells have to live in a
-- scratch buffer whose whole content is the image, with the image id as the
-- foreground colour of every cell.
--
-- Lifecycle: the cursor preview is transient in Normal mode (cursor movement
-- closes it, resting on an equation reopens it) and stays live in Insert mode,
-- where buffer changes refresh it instead of closing. The optional pane is a
-- persistent, screen-anchored preview that follows the equation under the
-- cursor and also refreshes while typing.

local api = vim.api
local util = require'mdmath.util'

local M = {}

local ns = api.nvim_create_namespace('mdmath-float')

-- Floats normally paint the `NormalFloat` panel. Reusing the editor's `Normal`
-- (and a `FloatBorder` copy with the same background) makes the window share
-- the buffer background: seamless on an opaque colorscheme, transparent when
-- `Normal` has no background. A window still covers the cells underneath; this
-- only removes the panel colour.
local TRANSPARENT_BORDER = 'MdMathPreviewBorder'

---@param win integer
local function make_transparent(win)
    -- Re-created on every open: `:colorscheme` clears custom highlight groups.
    local normal = api.nvim_get_hl(0, {name = 'Normal', link = false})
    local source = api.nvim_get_hl(0, {name = 'FloatBorder', link = false})
    local border = {
        bg = normal.bg and string.format('#%06x', normal.bg) or 'NONE',
        fg = source.fg and string.format('#%06x', source.fg) or nil,
        bold = source.bold,
        italic = source.italic,
        underline = source.underline,
        undercurl = source.undercurl,
        strikethrough = source.strikethrough,
        reverse = source.reverse,
        standout = source.standout,
    }
    api.nvim_set_hl(0, TRANSPARENT_BORDER, border)

    vim.wo[win].winhl = 'Normal:Normal,FloatBorder:' .. TRANSPARENT_BORDER
end

---@class mdmath.FloatOpts : mdmath.RenderOpts
---@field border string|nil window border; default 'rounded'
---@field title string|nil window title

---@alias mdmath.FloatCallback fun(win: integer|nil, err: string|nil)

local state = {
    generation = 0,
    win = nil,
    buf = nil,
    image = nil,
    tex = nil,
    bufnr = nil,
    pane = {
        enabled = false,
        generation = 0,
        win = nil,
        buf = nil,
        image = nil,
        tex = nil,
        bufnr = nil,
    },
}

-- Single reusable timer for the "cursor rested on an equation" debounce. It is
-- only started for buffers where the overlay is active: those already hold the
-- parsed equations, so the auto preview costs an O(#equations) lookup instead
-- of re-parsing the buffer on every cursor move.
local auto_timer = nil
-- Debounce shared by the pane and the insert-mode refresh of the preview.
local refresh_timer = nil
local hooked_overlay = false

local function cancel_auto()
    if auto_timer then
        auto_timer:stop()
    end
end

local function cancel_refresh()
    if refresh_timer then
        refresh_timer:stop()
    end
end

local function teardown()
    -- Detach the handles before closing: `WinClosed` fires synchronously inside
    -- `nvim_win_close`, and the handler must not think a live preview was
    -- closed by the user (that would bump the generation and drop the request
    -- that is replacing it).
    local win, buf = state.win, state.buf
    state.win = nil
    state.buf = nil
    state.tex = nil
    state.bufnr = nil

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

--- Hides the pane window but keeps the pane enabled.
local function teardown_pane()
    local win, buf = state.pane.win, state.pane.buf
    state.pane.win = nil
    state.pane.buf = nil
    state.pane.tex = nil
    state.pane.bufnr = nil

    if state.pane.image then
        state.pane.image:close()
        state.pane.image = nil
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
    cancel_auto()
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

--- Builds the read-only scratch buffer holding the placeholder cells.
---@param lines string[]
---@param id integer
---@return integer buf
local function build_buffer(lines, id)
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)

    -- The placeholder cells resolve to the image only when their foreground
    -- colour is the image id, the same rule the inline marks follow.
    local group = require'mdmath.highlight-colors'[id]
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
    return buf
end

--- Opens an image window: `cursor` is the transient preview, `pane` is the
--- persistent preview docked to the bottom-right of the editor.
---@param buf integer
---@param width integer
---@param height integer
---@param opts mdmath.FloatOpts
---@param anchor 'cursor'|'pane'
---@return integer win
local function open_window(buf, width, height, opts, anchor)
    local win
    if anchor == 'pane' then
        win = api.nvim_open_win(buf, false, {
            relative = 'editor',
            anchor = 'SE',
            row = 1,
            col = 0,
            width = width,
            height = height,
            style = 'minimal',
            border = opts.border or 'rounded',
            title = opts.title or ' mdmath ',
            focusable = false,
        })
    else
        win = api.nvim_open_win(buf, false, {
            relative = 'cursor',
            row = 1,
            col = 0,
            width = width,
            height = height,
            style = 'minimal',
            border = opts.border or 'rounded',
            title = opts.title,
            focusable = false,
        })
    end

    -- Re-created on every open: `:colorscheme` clears custom highlight groups.
    make_transparent(win)
    return win
end

---@param image mdmath.Image
---@param opts mdmath.FloatOpts
---@return integer win
local function show(image, opts)
    local buf = build_buffer(image:text(), image:color())
    local win = open_window(buf, image.cols, image.rows, opts, 'cursor')
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

    local bufnr = opts.bufnr or api.nvim_get_current_buf()

    cancel_auto()

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
        state.tex = tex
        state.bufnr = bufnr
        callback(win_or_err, nil)
    end)
end

--- TeX of the equation under the cursor. Uses the overlay's parsed equations
--- when the buffer is tracked (cheap) and falls back to Tree-sitter otherwise.
---@param bufnr integer
---@return string|nil
local function equation_text_at_cursor(bufnr)
    local overlay = package.loaded['mdmath.overlay']
    if overlay and overlay.is_enabled(bufnr) then
        local cursor = api.nvim_win_get_cursor(0)
        local equation = overlay.equation_at(bufnr, cursor[1] - 1, cursor[2])
        return equation and equation.equation or nil
    end
    return M.equation_under_cursor(bufnr)
end

---@param bufnr integer
---@param tex string|nil
local function refresh_pane(bufnr, tex)
    if not tex then
        -- Keep the pane enabled but hide it while the cursor is elsewhere.
        teardown_pane()
        return
    end
    if state.pane.win and state.pane.tex == tex and state.pane.bufnr == bufnr then
        return
    end

    state.pane.generation = state.pane.generation + 1
    local generation = state.pane.generation
    require'mdmath.api'.render(tex, {bufnr = bufnr}, function(image, err)
        if generation ~= state.pane.generation or not state.pane.enabled then
            if image then
                image:close()
            end
            return
        end
        if not image then
            -- Mid-edit TeX: keep the last good image instead of flashing.
            return
        end
        teardown_pane()
        local buf = build_buffer(image:text(), image:color())
        local win = open_window(buf, image.cols, image.rows, {}, 'pane')
        state.pane.buf = buf
        state.pane.win = win
        state.pane.image = image
        state.pane.tex = tex
        state.pane.bufnr = bufnr
    end)
end

--- Re-reads the equation under the cursor and updates the pane and the live
--- preview. Called from the debounce timer and from overlay parse updates.
function M.refresh()
    local bufnr = api.nvim_get_current_buf()
    local tex = equation_text_at_cursor(bufnr)

    if state.pane.enabled then
        refresh_pane(bufnr, tex)
    end

    if not state.win then
        return
    end
    if not tex then
        M.close()
        return
    end
    if state.tex == tex and state.bufnr == bufnr then
        -- Keep the window under the cursor while the line moves.
        pcall(api.nvim_win_set_config, state.win, {relative = 'cursor', row = 1, col = 0})
        return
    end
    M.preview(tex, {bufnr = bufnr}, function() end)
end

local hook_overlay

--- Debounces `refresh()` for the pane and for insert-mode typing.
local function schedule_refresh()
    cancel_refresh()
    if not (state.win or state.pane.enabled) then
        return
    end
    hook_overlay()

    if not refresh_timer then
        refresh_timer = assert(vim.uv.new_timer())
    end
    refresh_timer:start(require'mdmath.config'.opts.update_interval, 0, vim.schedule_wrap(function()
        M.refresh()
    end))
end

--- Registers the overlay hook once, so the preview follows parsed edits even
--- when the text changes faster than the cursor does.
hook_overlay = function()
    if hooked_overlay then
        return
    end
    local overlay = package.loaded['mdmath.overlay']
    if not overlay then
        return
    end
    hooked_overlay = true
    overlay.on_update(function()
        if state.win or state.pane.enabled then
            schedule_refresh()
        end
    end)
end

--- Toggles the persistent preview pane.
function M.pane_toggle()
    if state.pane.enabled then
        M.pane_close()
        return
    end
    state.pane.enabled = true
    -- One image is enough: drop the cursor-anchored preview while the pane is on.
    M.close()
    M.refresh()
end

--- Closes the pane and disables it until `pane_toggle()` runs again.
function M.pane_close()
    state.pane.enabled = false
    state.pane.generation = state.pane.generation + 1
    teardown_pane()
end

---@return integer|nil
function M.pane_win()
    if state.pane.win and api.nvim_win_is_valid(state.pane.win) then
        return state.pane.win
    end
    return nil
end

---@return boolean
function M.pane_enabled()
    return state.pane.enabled
end

--- Arms the debounce that opens the preview once the cursor has been resting on
--- an equation for `update_interval` milliseconds.
local function schedule_auto()
    cancel_auto()

    local config = require'mdmath.config'.opts
    if not config.preview_on_cursor or state.pane.enabled then
        return
    end

    hook_overlay()

    local bufnr = api.nvim_get_current_buf()
    if not vim.tbl_contains(config.filetypes, vim.bo[bufnr].filetype) then
        return
    end
    if vim.fn.mode() ~= 'n' then
        return
    end

    if not auto_timer then
        auto_timer = assert(vim.uv.new_timer())
    end

    auto_timer:start(config.update_interval, 0, vim.schedule_wrap(function()
        if state.win or api.nvim_get_current_buf() ~= bufnr or vim.fn.mode() ~= 'n' then
            return
        end

        local overlay = package.loaded['mdmath.overlay']
        if not overlay then
            return
        end

        local cursor = api.nvim_win_get_cursor(0)
        local equation = overlay.equation_at(bufnr, cursor[1] - 1, cursor[2])
        if not equation then
            return
        end

        M.preview(equation.equation, {bufnr = bufnr}, function() end)
    end))
end

local group = api.nvim_create_augroup('MdMathPreview', {clear = true})

api.nvim_create_autocmd({'CursorMoved', 'WinScrolled'}, {
    group = group,
    callback = function()
        if vim.fn.mode():sub(1, 1) == 'i' then
            schedule_refresh()
            return
        end
        M.close()
        schedule_auto()
        schedule_refresh()
    end,
})

-- Insert mode keeps the preview: typing must update it, not dismiss it.
api.nvim_create_autocmd({'CursorMovedI', 'TextChanged', 'TextChangedI', 'InsertLeave'}, {
    group = group,
    callback = function()
        schedule_refresh()
    end,
})

api.nvim_create_autocmd('InsertEnter', {
    group = group,
    callback = function()
        schedule_refresh()
    end,
})

api.nvim_create_autocmd({'BufLeave', 'WinLeave'}, {
    group = group,
    callback = function()
        M.close()
        teardown_pane()
    end,
})

api.nvim_create_autocmd('BufEnter', {
    group = group,
    callback = function()
        schedule_refresh()
    end,
})

api.nvim_create_autocmd('WinClosed', {
    group = group,
    callback = function(args)
        local win = tonumber(args.match)
        if state.win and win == state.win then
            M.close()
        elseif state.pane.win and win == state.pane.win then
            teardown_pane()
        end
    end,
})

return M
