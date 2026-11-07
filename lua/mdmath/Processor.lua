local vim = vim
local api = vim.api
local uv = vim.loop
local config = require'mdmath.config'.opts
local util = require'mdmath.util'

local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local processor_dir = plugin_dir .. '/mdmath-js'

local get_next_id
do
    local id = 0
    get_next_id = function()
        id = id + 1
        return tostring(id)
    end
end

local PROCESS_PATH = processor_dir .. '/src/processor.js'

-- Bumped whenever the wire format changes. It is passed to the JS process as
-- argv[2]; the two halves refuse to talk to each other on a mismatch, which
-- turns "silent drift" (field order changed on one side only, no reply ever
-- arrives) into an immediate, readable failure. Change both sides together.
local PROTOCOL_VERSION = 1

--- One rendered image, as described by the processor over the IPC wire.
---@class mdmath.Processor.Result
---@field width integer cells
---@field height integer cells
---@field data string absolute path of the PNG

---@alias mdmath.Processor.Callback fun(res: mdmath.Processor.Result|nil, err: string|nil)

---@class mdmath.Processor
---@field callbacks table<string, mdmath.Processor.Callback>|nil nil once closed
---@field pipes table<integer, uv.uv_pipe_t>
---@field is_closing boolean
---@field closed boolean
---@field handle uv.uv_process_t|nil
---@field err_buffer string[]
---@field _assert fun(self: mdmath.Processor, condition: any, ...: any)
---@field _init fun(self: mdmath.Processor)
---@field new fun(): mdmath.Processor
local Processor = util.class 'Processor'

--- Raises a formatted error and closes the processor.
---@param condition any falsy values abort
---@param ... any message parts, concatenated
function Processor:_assert(condition, ...)
    local message = table.concat(vim.iter({ ... }):flatten():totable())
    if not condition then
        self:close()
        error(message)
    end
end

---@param identifier string
---@param data_type string
---@param width integer
---@param height integer
---@param data string
function Processor:_on_data(identifier, data_type, width, height, data)
    -- Data may arrive after `close()`, in which case there is nothing to dispatch to.
    if not self.callbacks then
        return
    end

    local callback = self.callbacks[identifier]
    if not callback then
        return util.err_message('no callback for identifier: ', identifier)
    end
    self.callbacks[identifier] = nil

    if data_type == 'image' then
        callback({
            width = width,
            height = height,
            data = data
        })
    elseif data_type == 'error' then
        callback(nil, data)
    end
end

-- function Processor:setForeground(color)
--     if type(color) == 'number' then
--         color = string.format('#%06x', color)
--     elseif type(color) ~= 'string' then
--         error('color: expected string|number, got ' .. type(color))
--     end

--     local code, err = self.pipes[0]:write(string.format("0:fgcolor:%s:", color))
--     self:_assert(not err, 'failed to set foreground: ', err)
-- end

---@param scale number
function Processor:setInternalScale(scale)
    local _, err = self.pipes[0]:write(string.format("0:iscale:%.2f:", scale))
    self:_assert(not err, 'failed to set internal scale: ', err)
end

---@param scale number
function Processor:setDynamicScale(scale)
    local _, err = self.pipes[0]:write(string.format("0:dscale:%.2f:", scale))
    self:_assert(not err, 'failed to set dynamic scale: ', err)
end

--- Sends one equation to the renderer. Exactly one callback is invoked.
---@param data string TeX source without the surrounding `$`
---@param cell_width integer pixels
---@param cell_height integer pixels
---@param width integer cells
---@param height integer cells
---@param flags integer 0=none, 1=dynamic, 2=center, 3=dynamic+center
---@param color string `#rrggbb`
---@param callback mdmath.Processor.Callback
function Processor:request(data, cell_width, cell_height, width, height, flags, color, callback)
    -- width/height should be number of cells
    -- flags: 0: none, 1: dynamic, 2: center, 3: dynamic + center
    --        TODO: flags should be a enum

    if not self.callbacks then
        return util.err_message('cannot request: processor is closed')
    end

    local identifier = get_next_id()
    if self.callbacks[identifier] then
        return util.err_message('identifier already in use: ', identifier, ' (how the hell did this happen?)')
    end
    self.callbacks[identifier] = callback

    local _, err =
        self.pipes[0]:write(string.format("%s:request:%d:%s:%d:%d:%d:%d:%d:%s",
            identifier, flags, color, cell_width, width, cell_height, height, #data, data))

    self:_assert(not err, 'failed to request: ', err)
end

--- Reads the length-prefixed responses coming from the processor's stdout.
function Processor:_listen()
    local separator = string.byte(':')

    -- TODO: use JSON instead of custom protocol
    local states = {
        READING_IDENTIFIER = 0,
        READING_TYPE = 1,
        READING_WIDTH = 2,
        READING_HEIGHT = 3,
        READING_LENGTH = 4,
        READING_DATA = 5
    }

    local state = states.READING_IDENTIFIER
    local identifier = ""
    local data_type = ""
    local width = 0
    local height = 0
    local length = 0
    local buffer = {}

    local function process_byte(byte)
        if state == states.READING_IDENTIFIER then
            if byte == separator then
                identifier = table.concat(buffer)
                buffer = {}
                state = states.READING_TYPE
            else
                table.insert(buffer, string.char(byte))
            end
        elseif state == states.READING_TYPE then
            if byte == separator then
                data_type = table.concat(buffer)
                self:_assert(data_type == "image" or data_type == "error", "Invalid data type: ", data_type)
                buffer = {}
                state = states.READING_WIDTH
            else
                table.insert(buffer, string.char(byte))
            end
        elseif state == states.READING_WIDTH then
            if byte == separator then
                local width_str = table.concat(buffer)
                width = tonumber(width_str) --[[@as integer]]
                self:_assert(width, "Invalid width: ", width_str)
                buffer = {}
                state = states.READING_HEIGHT
            else
                table.insert(buffer, string.char(byte))
            end
        elseif state == states.READING_HEIGHT then
            if byte == separator then
                local height_str = table.concat(buffer)
                height = tonumber(height_str) --[[@as integer]]
                self:_assert(height, "Invalid height: ", height_str)
                buffer = {}
                state = states.READING_LENGTH
            else
                table.insert(buffer, string.char(byte))
            end
        elseif state == states.READING_LENGTH then
            if byte == separator then
                local length_str = table.concat(buffer)
                length = tonumber(length_str) --[[@as integer]]
                self:_assert(length, "Invalid length: ", length_str)
                buffer = {}
                state = states.READING_DATA
            else
                table.insert(buffer, string.char(byte))
            end
        elseif state == states.READING_DATA then
            table.insert(buffer, string.char(byte))
            if #buffer == length then
                self:_on_data(identifier, data_type, width, height, table.concat(buffer))
                state = states.READING_IDENTIFIER
                buffer = {}
            end
        end
    end

    local code, err = uv.read_start(self.pipes[1], function(err, data)
        if data then
            for i = 1, #data do
                local byte = data:byte(i)
                process_byte(byte)
            end
        end
    end)

    self:_assert(code == 0, 'failed to start reading from out pipe: ', err)
end

--- Spawns the node.js process and starts listening on its pipes.
function Processor:_init()
    self.callbacks = {}

    local err
    self.pipes = {}
    for i = 0, 2 do
        self.pipes[i], err = uv.new_pipe()
        self:_assert(self.pipes[i], 'failed to open pipe ', i, ': ', err)
    end

    self.is_closing = false
    self.closed = false

    self.handle, err = uv.spawn('node', {
        args = { PROCESS_PATH, tostring(PROTOCOL_VERSION) },
        stdio = { self.pipes[0], self.pipes[1], self.pipes[2] }
    }, function(code, signal)
        if code == 0 and signal == 0 then
            self:_assert(not self.is_closing, 'processor closed unexpectedly')

            self.is_closing = false
            self.closed = true
        else
            local err = table.concat(self.err_buffer)
            self:close()
            -- Report instead of throwing: this runs inside a libuv callback, where
            -- `error()` only produces a "Error executing luv callback" stack that
            -- buries the child's own message (protocol mismatch, missing binary).
            util.err_message('processor runtime error: ', err)
        end
    end)
    self:_assert(self.handle, 'failed to spawn LatexProcessor: ', err)

    self.err_buffer = {}
    local code, err = uv.read_start(self.pipes[2], function(err, data)
        if data then
            table.insert(self.err_buffer, data)
        end
    end)
    self:_assert(code == 0, 'failed to start reading from err pipe: ', err)

    self:_listen()

    -- self:setForeground(config.foreground)
    self:setInternalScale(config.internal_scale)
    self:setDynamicScale(config.dynamic_scale)
end

--- Closes every pipe and the child process. Pending callbacks are dropped.
function Processor:close()
    if self.closed or self.is_closing then
        return
    end

    self.is_closing = true
    self.callbacks = nil

    for i = 0, 2 do
        if self.pipes[i] then
            self.pipes[i]:close()
            self.pipes[i] = nil
        end
    end
    if self.handle ~= nil then
        self.handle:close()
        self.handle = nil
    end
end

---@type mdmath.Processor|nil
local processor = nil
local ref_count = 0
local buffers = {}

local M = {}

local function detach(bufnr)
    ref_count = ref_count - 1
    if ref_count == 0 and processor then
        processor:close()
        processor = nil
    end
end

local function on_detach(_, bufnr)
    if buffers[bufnr] == false then
        buffers[bufnr] = nil
    elseif buffers[bufnr] == true then
        buffers[bufnr] = nil
        detach(bufnr)
    end
end

--- Shared processor for a buffer, spawning it on first use and ref-counting
--- buffers so it is closed when the last one detaches.
---@param bufnr integer 0 means the current buffer
---@return mdmath.Processor
function M.from_bufnr(bufnr)
    assert(type(bufnr) == 'number', 'bufnr is required')
    bufnr = bufnr == 0 and api.nvim_get_current_buf() or bufnr

    if buffers[bufnr] then
        return assert(processor)
    end

    if ref_count == 0 then
        processor = Processor.new()
    end
    ref_count = ref_count + 1

    local should_attach = (buffers[bufnr] == nil)
    buffers[bufnr] = true

    if should_attach then
        local success = api.nvim_buf_attach(bufnr, false, {
            on_detach = on_detach,
        })
        if not success then
            buffers[bufnr] = nil
            detach(bufnr)
            error('failed to attach to buffer ' .. bufnr)
        end
    end

    return assert(processor)
end

--- Closes the processor and forgets every buffer (used on `VimLeave`).
function M.stop_instance()
    for bufnr, _ in pairs(buffers) do
        if buffers[bufnr] then
            -- mark false to prevent on_detach from being called multiple times
            buffers[bufnr] = false
            detach(bufnr)
        end
    end
end

return M
