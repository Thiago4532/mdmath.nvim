-- `:checkhealth mdmath` provider.
--
-- Everything here is defensive: health checks run from a user's broken setup,
-- so no module is required at load time (the plugin modules read the options on
-- `require`, which errors before `setup()`), and no handle is created that
-- could take ownership of stdout.

local M = {}

local health = vim.health

local function plugin_root()
    return vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
end

--- @param name string
--- @param args string[]
--- @return string|nil first line of output
local function first_line(name, args)
    local exe = vim.fn.exepath(name)
    if exe == '' then
        return nil
    end

    local out = vim.fn.systemlist({ exe, unpack(args) })
    if vim.v.shell_error ~= 0 or #out == 0 then
        return nil
    end
    return out[1]
end

local function check_neovim()
    health.start('mdmath.nvim: vim')

    if vim.fn.has('nvim-0.10') == 1 then
        local version = vim.version()
        health.ok(string.format('Neovim %d.%d.%d', version.major, version.minor, version.patch))
    else
        health.error('Neovim >= 0.10 is required', 'Upgrade Neovim.')
    end
end

local function check_parsers()
    health.start('mdmath.nvim: parser')

    for _, lang in ipairs({ 'markdown', 'markdown_inline' }) do
        local ok, err = pcall(vim.treesitter.language.add, lang)
        if ok then
            health.ok(string.format('parser "%s" is installed', lang))
        else
            health.error(string.format('parser "%s" is missing', lang),
                'Install it with nvim-treesitter (`:TSInstall markdown markdown_inline`).')
        end
    end

    -- The parser alone is not enough: 0.12 keeps the `(inline)` injection query
    -- in nvim-treesitter, and without it every markdown_inline tree is skipped.
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'x $a$ y' })

    local injected = false
    local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, 'markdown')
    if ok_parser then
        -- Without a range Neovim 0.12 does not process injections at all.
        local ok_parse = pcall(parser.parse, parser, { 0, 1 })
        injected = ok_parse and parser:children()['markdown_inline'] ~= nil
    end
    vim.api.nvim_buf_delete(bufnr, { force = true })

    if injected then
        health.ok('markdown_inline injection is processed')
    else
        health.error('markdown_inline injection is not processed',
            'Install nvim-treesitter (it ships queries/markdown/injections.scm).')
    end
end

local function check_dependencies()
    health.start('mdmath.nvim: dependencies')

    local node = first_line('node', { '--version' })
    if node then
        local major = tonumber(node:match('v?(%d+)')) or 0
        if major >= 18 then
            health.ok('node ' .. node:gsub('^v', ''))
        else
            health.warn('node ' .. node:gsub('^v', '') .. ' is old',
                'Node.js >= 18 is recommended for MathJax.')
        end
    else
        health.error('node is not in PATH',
            'Install Node.js; without it equations cannot be rendered.')
    end

    if vim.fn.exepath('npm') ~= '' then
        health.ok('npm is in PATH (needed by `:MdMath build`)')
    else
        health.warn('npm is not in PATH', '`:MdMath build` will not work.')
    end

    local rsvg = first_line('rsvg-convert', { '--version' })
    if rsvg then
        health.ok(rsvg)
    else
        health.error('rsvg-convert is not in PATH',
            'Install librsvg (brew install librsvg / apt install librsvg2-bin).')
    end

    local magick = first_line('magick', { '-version' })
    if magick then
        health.ok(magick:gsub('%s+$', ''))
    else
        local convert = first_line('convert', { '-version' })
        local identify = first_line('identify', { '-version' })
        if convert and identify then
            health.ok(convert:gsub('%s+$', '') .. ' (ImageMagick v6)')
        else
            health.error('ImageMagick is not in PATH',
                'Install ImageMagick (v6 `convert`+`identify` or v7 `magick`).')
        end
    end

    local build = plugin_root() .. '/mdmath-js/node_modules/mathjax'
    if vim.uv.fs_stat(build) then
        health.ok('mdmath-js dependencies are installed')
    else
        health.error('mdmath-js dependencies are missing',
            'Run `:MdMath build` (or `npm install` inside mdmath-js).')
    end
end

local function check_config()
    health.start('mdmath.nvim: configuration')

    local ok_opts, opts = pcall(function()
        return require'mdmath.config'.opts
    end)

    if not ok_opts then
        health.error('options are not available',
            'Call `require\'mdmath\'.setup({})` before using the plugin.')
        return
    end

    health.ok(string.format(
        'transfer=%s, dynamic=%s, scales=%s/%s, update_interval=%s',
        tostring(opts.transfer), tostring(opts.dynamic),
        tostring(opts.dynamic_scale), tostring(opts.internal_scale),
        tostring(opts.update_interval)))

    health.info('foreground=' .. tostring(opts.foreground))
end

local function check_terminal()
    health.start('mdmath.nvim: terminal')

    -- `uv.new_tty` takes ownership of the file descriptor: creating one here and
    -- closing it would close stdout. `guess_handle` only inspects it.
    local ok_guess, handle = pcall(vim.uv.guess_handle, 1)
    if ok_guess and handle == 'tty' then
        health.ok('stdout is a tty')
    else
        health.error('stdout is not a tty',
            'Run Neovim in a terminal that supports the Kitty graphics protocol.')
    end

    local ok_size, size = pcall(require'mdmath.terminfo'.size)
    if ok_size and size and size.xpixel > 0 and size.ypixel > 0 then
        health.ok(string.format('cell size %dx%d px, %dx%d cells',
            math.floor(size.xpixel / size.col), math.floor(size.ypixel / size.row),
            size.col, size.row))
    else
        health.warn('terminal does not report pixel dimensions',
            'The plugin falls back to 8x16 px cells; equations may look blurry or misaligned.')
    end

    local term = vim.env.TERM or ''
    local program = vim.env.TERM_PROGRAM or ''
    health.info(string.format('TERM=%s, TERM_PROGRAM=%s', term ~= '' and term or '<unset>',
        program ~= '' and program or '<unset>'))
    health.info('Unicode placeholders are required: Kitty >= 0.28, Ghostty >= 1.0; '
        .. 'tmux needs `allow-passthrough` on.')

    if vim.env.TMUX and vim.env.TMUX ~= '' then
        health.warn('running inside tmux', 'Set `set -g allow-passthrough on`.')
    end
end

function M.check()
    check_neovim()
    check_parsers()
    check_dependencies()
    check_config()
    check_terminal()
end

return M
