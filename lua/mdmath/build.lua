local uv = vim.uv

local M = {}

local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local build_dir = plugin_dir .. '/mdmath-js'

--- Callbacks used to report progress; `build()` is callback-based because the
--- npm child process is asynchronous.
---@class mdmath.build.Listeners
---@field on_log fun(msg: string)
---@field on_error fun(msg: string)
---@field on_done fun()

--- Runs `npm install` inside `mdmath-js`.
---@param L mdmath.build.Listeners
local function build(L)
    -- TODO: Check if build_dir exists

    local stderr, err = uv.new_pipe(false)
    if not stderr then
        L.on_error("Failed to create stderr pipe: " .. err)
        L.on_done()
        return
    end

    L.on_log('Running npm install...')

    local err_msg = {}

    local handle, err
    local npm = vim.fn.has('win32') == 1 and 'npm.cmd' or 'npm'
    handle, err = uv.spawn(npm, {
        args = {'install'},
        stdio = {nil, nil, stderr},
        cwd = build_dir,
    }, function(code)
        assert(handle):close()
        stderr:close()
        if code ~= 0 then
            local msg = table.concat(err_msg)
            L.on_error(msg)
        end
        L.on_done()
    end)
    if not handle then
        -- TODO: Check if the error is ENOENT
        L.on_error("Failed to spawn npm: " .. err)
        stderr:close()
        L.on_done()
        return
    end

    uv.read_start(stderr, function(err, data)
        if data then
            table.insert(err_msg, data)
        end
    end)
end

--- `:MdMath build`: installs the node.js dependencies, reporting via messages.
function M.build()
    local success = true
    return build {
        on_log = function(msg)
            print('[mdmath]: ' .. msg)
        end,
        on_error = function(msg)
            success = false
            vim.schedule(function()
                vim.notify('[mdmath]: Build failed: ' .. msg, vim.log.levels.ERROR)
            end)
        end,
        on_done = function()
            if success then
                print('[mdmath]: Build done')
            end
        end,
    }
end

-- Build function to be used in lazy.nvim (it yields until npm finishes).
function M.build_lazy()
    local message = nil
    local done = false

    build {
        on_log = function(msg)
            message = {msg = msg, level = vim.log.levels.TRACE}
        end,
        on_error = function(msg)
            message = {msg = msg, level = vim.log.levels.ERROR}
        end,
        on_done = function()
            done = true
        end,
    }

    while not done do
        local msg = message
        message = nil

        coroutine.yield(msg)
    end
    coroutine.yield(message)
end

return M
