local uv = vim.loop
local util = require'mdmath.util'
local diacritics = require'mdmath.Image.diacritics'

-- Opened lazily: `uv.new_tty` fails when stdout is not a TTY (headless/CI), and
-- this module is loaded as soon as `Equation` is required.
---@type uv.uv_tty_t|false|nil
local stdout = nil
local warned_no_tty = false

---@return uv.uv_tty_t|nil
local function get_stdout()
    if stdout == nil then
        stdout = uv.new_tty(1, false) or false
        if not stdout and not warned_no_tty then
            warned_no_tty = true
            util.err_message('stdout is not a TTY, equations cannot be displayed')
        end
    end

    return stdout or nil
end

-- Kitty image ids must fit in 24 bits, because a placeholder cell's foreground
-- colour *is* the id. A fixed ring has two properties we need:
--   * restarting Neovim reuses the same ids, so images left behind by a previous
--     session (its `a=d` writes are async and may be lost on exit) get replaced
--     instead of accumulating in the terminal's scrollback until it starts
--     silently dropping new images -- which looks like "some equations stop
--     rendering after a restart";
--   * the id space stays bounded, so a long session cannot exhaust it either.
-- The range is deliberately far from what other image plugins pick.
local ID_BASE = 0xF00000
local ID_SLOTS = 256
local id_slot = 0
local ids_swept = false

--- Wraps an APC sequence so tmux forwards it (`allow-passthrough on`).
---@param sequence string
---@return string
local function tmux_escape(sequence)
    return "\x1bPtmux;" .. sequence:gsub("\x1b", "\x1b\x1b") .. "\x1b\\"
end

---@param params table<string, string|integer>
---@return string
local function serialize(params)
    local tbl = {}

    for k, v in pairs(params) do
        tbl[#tbl + 1] = tostring(k) .. "=" .. tostring(v)
    end

    return table.concat(tbl, ",")
end

---@param params table<string, string|integer>
---@param encoded string|nil base64 payload
---@return boolean
local function write_sequence(params, encoded)
    local out = get_stdout()
    if not out then
        return false
    end

    local message
    if encoded ~= nil then
        message = string.format("\x1b_G%s;%s\x1b\\", serialize(params), encoded)
    else
        message = string.format("\x1b_G%s\x1b\\", serialize(params))
    end

    local tmux = os.getenv("TMUX")
    if tmux and tmux ~= "" then
        message = tmux_escape(message)
    end

    local _, err = out:write(message)
    if err then
        util.err_message('failed to write to stdout: ', err)
        return false
    end

    return true
end

---@param params table<string, string|integer>
---@param payload string|nil raw bytes to transmit
---@return boolean
local function kitty_send(params, payload)
    if not params.q then
        params.q = 2
    end

    return write_sequence(params, payload ~= nil and vim.base64.encode(payload) or nil)
end

-- Free every id this plugin may have used in an earlier session. Cheap (256 tiny
-- sequences), idempotent, and scoped: it never touches ids outside our range.
local function sweep_ids()
    if ids_swept then
        return
    end
    ids_swept = true

    for i = 0, ID_SLOTS - 1 do
        kitty_send({i = ID_BASE + i, a = 'd', d = 'I'})
    end
end

local function next_id()
    local id = ID_BASE + (id_slot % ID_SLOTS)
    id_slot = id_slot + 1

    -- Delete the slot before reuse: it may still hold an image (and placements
    -- in the scrollback) from a previous session or an older wrap.
    kitty_send({i = id, a = 'd', d = 'I'})
    return id
end

-- A single escape sequence may carry at most 4096 base64 bytes. 1536 raw bytes
-- encode to 2048 base64 characters (no padding: 1536 is a multiple of 3), which
-- keeps one sequence well below both that limit and a typical tty buffer, so a
-- partial write cannot easily split it.
local CHUNK_SIZE = 1536

---@param params table<string, string|integer>
---@param data string raw PNG bytes
---@return boolean
local function kitty_send_data(params, data)
    local total = #data
    if total == 0 then
        return false
    end

    local offset = 1
    local first = true

    while offset <= total do
        local last = math.min(offset + CHUNK_SIZE - 1, total)
        local more = last < total and 1 or 0

        local chunk
        if first then
            -- Control keys are only read from the first chunk.
            chunk = vim.tbl_extend('force', params, {f = 100, t = 'd', m = more, q = 2})
        else
            chunk = {m = more}
        end

        if not write_sequence(chunk, vim.base64.encode(data:sub(offset, last))) then
            return false
        end

        offset = last + 1
        first = false
    end

    return true
end

---@type 'file'|'direct'|nil
local transfer_mode = nil

-- File transmission writes a ~60 byte sequence (the PNG path) per image. Direct
-- transmission streams the whole PNG as base64: those writes go through a
-- non-blocking tty, can be split into several `write()` calls, and Neovim's own
-- redraw output may land in the middle of the escape sequence. The terminal then
-- aborts the APC and prints the remaining base64 as literal text, which is both
-- corrupting and nondeterministic (more chunks, bigger image, higher chance).
-- So `file` is the default everywhere; `direct` is opt-in for terminals that
-- cannot read a file path.
---@return 'file'|'direct'
local function get_transfer_mode()
    if transfer_mode then
        return transfer_mode
    end

    local mode = require'mdmath.config'.opts.transfer
    -- `auto` resolves to `file`: a path-based transfer is the only reliable one.
    transfer_mode = mode == 'direct' and 'direct' or 'file'

    return transfer_mode
end

---@param path string
---@return string|nil data
---@return string|nil err
local function read_file(path)
    local fd, open_err = uv.fs_open(path, 'r', 438)
    if not fd then
        return nil, open_err
    end

    local stat, stat_err = uv.fs_fstat(fd)
    if not stat then
        uv.fs_close(fd)
        return nil, stat_err
    end

    local data, read_err = uv.fs_read(fd, stat.size, 0)
    uv.fs_close(fd)

    if not data then
        return nil, read_err
    end

    return data
end

--- A virtual placement (`U=1`) of one PNG, addressed by a fixed id ring.
---@class mdmath.Image
---@field id integer|nil nil once closed
---@field rows integer
---@field cols integer
---@field _init fun(self: mdmath.Image, rows: integer, cols: integer, payload: string): false|nil
---@field new fun(rows: integer, cols: integer, payload: string): mdmath.Image?
local Image = util.class 'Image'

function Image:__tostring()
    return string.format('<Image id=%d>', self.id)
end

function Image:_init(rows, cols, payload)
    if not get_stdout() then
        -- No TTY: `Image.new` returns nil and callers just skip the mark.
        return false
    end

    sweep_ids()

    local id = next_id()
    if self.id then
        self:close()
    end

    self.id = id
    self.rows = rows
    self.cols = cols

    -- A "virtual placement" (`U=1`) is what makes the placeholder cells resolve:
    -- nothing is drawn at the cursor, the image only appears where U+10EEEE cells
    -- carrying this image id as their foreground colour are printed.
    --
    -- Terminals differ in how the placement is created:
    --   * Kitty (upstream-tested path): transmit with `a=t`, then `a=p,U=1`.
    --   * Ghostty: only honours the combined `a=T,U=1` form.
    -- So `file` mode (Kitty) keeps the upstream sequence, `direct` mode (every
    -- other terminal) uses the combined one.
    if get_transfer_mode() == 'direct' then
        local data, read_err = read_file(payload)
        if not data then
            util.err_message('failed to read rendered image (', tostring(read_err), '): ', payload)
            return false
        end

        local placement = {i = id, a = 'T', U = 1, r = rows, c = cols}
        if not kitty_send_data(placement, data) then
            self:close()
            return false
        end
    else
        if not kitty_send({i = id, f = 100, t = 'f'}, payload) then
            self:close()
            return false
        end

        if not kitty_send({i = id, U = 1, a = 'p', r = rows, c = cols}) then
            self:close()
            return false
        end
    end
end

--- Placeholder cell for (row, col); the diacritics carry the cell coordinates.
---@param row integer 1-indexed
---@param col integer 1-indexed
---@return string
function Image.unicode_at(row, col)
    return '\u{10EEEE}' .. diacritics[row] .. diacritics[col]
end

--- One placeholder string per image row.
---@return string[]
function Image:text()
    local text = {}
    for row = 1, self.rows do
        local T = {}
        for col = 1, self.cols do
            T[#T + 1] = Image.unicode_at(row, col)
        end
        text[#text + 1] = table.concat(T)
    end
    return text
end

--- The image id doubles as the placeholder foreground colour.
---@return integer
function Image:color()
    return self.id -- Color is represented by the id
end

--- Deletes the image (and its placements) from the terminal. Idempotent.
function Image:close()
    if not self.id then
        return
    end

    kitty_send({i = self.id, a = 'd', d = 'I'})
    self.id = nil
end

return Image
