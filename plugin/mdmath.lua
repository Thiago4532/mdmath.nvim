local api = vim.api

-- This only sets up the plugin at the startup. If you load this plugin after
-- the vim has started, make sure to call `require'mdmath'.setup()` manually.
if not vim.g.mdmath_disable_auto_setup and vim.v.vim_did_enter ~= 1 then
    api.nvim_create_autocmd('VimEnter', {
        callback = function()
            require'mdmath'.setup()
        end
    })
end

---@type string[]
local subcommands = {
    'enable', 'disable', 'clear', 'build', 'preview', 'pane'
}

api.nvim_create_user_command('MdMath', function(opts)
    local cmd = opts.fargs[1]
    if not vim.tbl_contains(subcommands, cmd) then
        vim.notify('MdMath: invalid subcommand: ' .. cmd, vim.log.levels.ERROR)
        return
    end

    require'mdmath'[cmd]()
end, {
    nargs = 1,
    complete = function()
        return subcommands
    end,
});
