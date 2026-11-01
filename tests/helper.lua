-- Shared harness for the headless specs.
--
-- Every spec runs in its own Neovim process: `mdmath.setup()` may only run once
-- per process (options are read when modules load, then frozen), and several
-- specs need different options.
--
-- A spec looks like:
--
--   local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
--   local t = dofile(root .. '/tests/helper.lua')
--   t.bootstrap()
--   require'mdmath'.setup({})
--   t.eq(1 + 1, 2, 'addition')
--   t.finish()

local M = {}

local passed, failed, skipped = 0, 0, 0

function M.root()
    return vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
end

function M.bootstrap()
    local root = M.root()
    vim.opt.rtp:prepend(root)

    -- Neovim 0.12 keeps the `markdown_inline` injection query in nvim-treesitter,
    -- not in the built-in runtime.
    local candidates = {
        vim.env.NVIM_TREESITTER_RUNTIME,
        vim.fn.expand('~/.local/share/nvim/lazy/nvim-treesitter/runtime'),
    }
    vim.list_extend(candidates, vim.fn.glob(
        vim.fn.expand('~/.local/share/nvim/site/pack/*/start/nvim-treesitter/runtime'),
        false, true))

    for _, path in ipairs(candidates) do
        if path and path ~= '' and vim.uv.fs_stat(path) then
            vim.opt.rtp:append(path)
            break
        end
    end

    return root
end

--- The image path needs a real TTY, node, MathJax and ImageMagick.
--- @return boolean, string|nil
function M.has_render_deps(root)
    if vim.uv.fs_stat(root .. '/mdmath-js/node_modules/mathjax') == nil then
        return false, 'mdmath-js/node_modules is missing (run :MdMath build)'
    end
    for _, bin in ipairs({ 'node', 'rsvg-convert' }) do
        if vim.fn.executable(bin) == 0 then
            return false, bin .. ' is not in PATH'
        end
    end
    local has_magick = vim.fn.executable('magick') == 1
        or (vim.fn.executable('convert') == 1 and vim.fn.executable('identify') == 1)
    if not has_magick then
        return false, 'ImageMagick is not in PATH'
    end
    return true
end

--- @return boolean found nvim-treesitter's markdown injections query
function M.has_injection_query()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'x $a$ y' })

    local found = false
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, 'markdown')
    if ok then
        -- Without a range Neovim 0.12 skips injection processing entirely.
        found = pcall(parser.parse, parser, { 0, 1 }) and parser:children()['markdown_inline'] ~= nil
    end

    vim.api.nvim_buf_delete(bufnr, { force = true })
    return found
end

--- Ends the spec early when the parser/queries it needs are unavailable.
function M.skip_without_injection()
    if M.has_injection_query() then
        return
    end
    M.skip('markdown_inline injection query', 'install nvim-treesitter')
    M.finish()
end

function M.ok(condition, label)
    if condition then
        passed = passed + 1
        print('ok - ' .. label)
    else
        failed = failed + 1
        print('not ok - ' .. label)
    end
    return condition
end

function M.eq(actual, expected, label)
    return M.ok(actual == expected,
        string.format('%s (got %s, want %s)', label, vim.inspect(actual), vim.inspect(expected)))
end

function M.skip(label, reason)
    skipped = skipped + 1
    print(('ok - %s # SKIP %s'):format(label, reason or ''))
end

function M.wait_for(predicate, timeout, interval)
    return vim.wait(timeout or 30000, predicate, interval or 25)
end

--- Replaces the Kitty transport. Marks are still created for real, which is what
--- the mark/lifecycle specs assert; nothing is written to the terminal.
function M.stub_image()
    local Image = require'mdmath.Image'
    Image.new = function(rows, cols)
        local image = { id = 1, rows = rows, cols = cols }
        function image:text()
            local out = {}
            for row = 1, rows do
                local cells = {}
                for col = 1, cols do
                    cells[#cells + 1] = Image.unicode_at(row, col)
                end
                out[#out + 1] = table.concat(cells)
            end
            return out
        end
        function image:color()
            return self.id
        end
        function image:close()
        end
        return image
    end
end

--- Replaces the node.js IPC. Call after `mdmath.setup()`: loading the module
--- reads the configuration.
function M.stub_processor()
    local Processor = require'mdmath.Processor'
    Processor.from_bufnr = function()
        return {
            request = function(_, _, _, _, width, height, _, _, callback)
                vim.schedule(function()
                    callback({
                        width = width,
                        height = height,
                        data = '/tmp/mdmath-stub.png',
                    }, nil)
                end)
            end,
        }
    end
end

--- Records every `marks.add` call. Returns the list; call before enabling.
function M.collect_marks()
    local marks = require'mdmath.marks'
    local added = {}
    local real_add = marks.add

    marks.add = function(bufnr, row, col, opts)
        local id = real_add(bufnr, row, col, opts)
        added[#added + 1] = { bufnr = bufnr, row = row, col = col, opts = opts, id = id }
        return id
    end

    return added
end

--- Builds a markdown buffer and makes it current.
function M.markdown_buffer(lines)
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].filetype = 'markdown'
    return bufnr
end

--- Forces the overlay to parse the whole buffer instead of the window viewport.
function M.full_view(lines)
    local util = require'mdmath.util'
    util.get_current_view = function()
        return 0, #lines
    end
end

function M.finish()
    print('')
    print(('1..%d'):format(passed + failed + skipped))
    print(('# passed=%d failed=%d skipped=%d'):format(passed, failed, skipped))
    io.stdout:flush()
    os.exit(failed == 0 and 0 or 1)
end

return M
