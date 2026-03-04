local M = {}

local function check_neovim_version()
    vim.health.start("mdmath.nvim: Neovim version")
    if vim.fn.has("nvim-0.10") == 1 then
        vim.health.ok("Neovim >= 0.10 detected")
    else
        vim.health.error(
            "Neovim >= 0.10 is required",
            "Please upgrade Neovim: https://github.com/neovim/neovim/releases"
        )
    end
end

local function check_treesitter_parsers()
    vim.health.start("mdmath.nvim: Tree-sitter parsers")

    local required_parsers = { "markdown", "markdown_inline" }
    for _, lang in ipairs(required_parsers) do
        local ok, _ = pcall(vim.treesitter.language.inspect, lang)
        if ok then
            vim.health.ok(("Parser `%s` is installed"):format(lang))
        else
            vim.health.error(
                ("Parser `%s` is NOT installed"):format(lang),
                ("Install it with: :TSInstall %s"):format(lang)
            )
        end
    end
end

local function check_node()
    vim.health.start("mdmath.nvim: Node.js / npm")

    -- Check node
    if vim.fn.executable("node") == 1 then
        local node_version = vim.fn.system("node --version"):gsub("%s+", "")
        vim.health.ok(("`node` found: %s"):format(node_version))
    else
        vim.health.error("`node` not found in PATH", "Install Node.js from https://nodejs.org/")
    end

    -- Check npm
    if vim.fn.executable("npm") == 1 then
        local npm_version = vim.fn.system("npm --version"):gsub("%s+", "")
        vim.health.ok(("`npm` found: %s"):format(npm_version))
    else
        vim.health.error("`npm` not found in PATH", "Install npm from https://nodejs.org/")
    end
end

local function check_build()
    vim.health.start("mdmath.nvim: JS processor build")

    local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
    local build_dir = plugin_dir .. "/mdmath-js"
    local processor_js = build_dir .. "/src/processor.js"
    local node_modules = build_dir .. "/node_modules"

    if vim.fn.isdirectory(build_dir) == 1 then
        vim.health.ok(("Build directory found: %s"):format(build_dir))
    else
        vim.health.error(
            ("Build directory not found: %s"):format(build_dir),
            "The plugin may not be installed correctly."
        )
        return
    end

    if vim.fn.filereadable(processor_js) == 1 then
        vim.health.ok("`src/processor.js` exists")
    else
        vim.health.error("`src/processor.js` not found", "The plugin source files may be missing or corrupt.")
    end

    if vim.fn.isdirectory(node_modules) == 1 then
        vim.health.ok("`node_modules` directory exists (build complete)")
    else
        vim.health.warn(
            "`node_modules` not found — the plugin has not been built yet",
            'Run `:MdMath build` or the build step in your plugin manager (e.g., `build = "npm install"`).'
        )
    end
end

local function check_terminal()
    vim.health.start("mdmath.nvim: Terminal support")

    -- Check for tmux (warn about potential compatibility)
    local tmux = os.getenv("TMUX")
    if tmux and tmux ~= "" then
        vim.health.warn("Running inside tmux", {
            "Kitty graphics protocol passthrough requires tmux >= 3.3.",
            "Make sure `set -g allow-passthrough on` is set in your tmux config.",
        })
    else
        vim.health.ok("Not inside tmux (no passthrough concerns)")
    end

    -- Check TERM / TERM_PROGRAM for Kitty
    local term = os.getenv("TERM") or ""
    local term_program = os.getenv("TERM_PROGRAM") or ""
    local kitty_window_id = os.getenv("KITTY_WINDOW_ID")

    if kitty_window_id then
        vim.health.ok("Kitty terminal detected")
    elseif term:find("kitty") or term:find("xterm-ghostty") then
        vim.health.ok(("Kitty-compatible TERM detected: %s"):format(term))
    elseif term_program:lower():find("kitty") or term_program:lower():find("ghostty") then
        vim.health.ok(("Kitty-compatible TERM_PROGRAM detected: %s"):format(term_program))
    else
        vim.health.warn(
            ("Terminal may not support Kitty graphics protocol (TERM=%s, TERM_PROGRAM=%s)"):format(term, term_program),
            {
                "mdmath.nvim uses the Kitty graphics protocol to render equations.",
                "Supported terminals include: kitty, ghostty, and others with Kitty protocol support.",
                "See: https://sw.kovidgoyal.net/kitty/graphics-protocol/",
            }
        )
    end
end

function M.check()
    check_neovim_version()
    check_treesitter_parsers()
    check_node()
    check_build()
    check_terminal()
end

return M
