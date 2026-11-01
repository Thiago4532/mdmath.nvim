-- Runs every `tests/spec/*_spec.lua` in a fresh Neovim process and aggregates
-- the exit codes, so a spec that fails (or crashes) cannot poison the next one.
--
-- Usage: nvim --headless --clean -l tests/runner.lua
--
-- Each spec prints TAP-ish lines and exits non-zero on failure.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local specs = vim.fn.glob(root .. '/tests/spec/*_spec.lua', false, true)
table.sort(specs)

if #specs == 0 then
    print('no specs found under ' .. root .. '/tests/spec')
    os.exit(1)
end

local failed = {}

for _, spec in ipairs(specs) do
    local name = vim.fn.fnamemodify(spec, ':t')
    print('# ' .. name)

    local result = vim.system(
        { vim.v.progpath, '--headless', '--clean', '-l', spec },
        { cwd = root, text = true, timeout = 180000 }
    ):wait()

    io.write(result.stdout or '')
    -- Neovim's Lua `print` goes to stderr when headless: always forward both.
    io.write(result.stderr or '')
    if result.code ~= 0 then
        failed[#failed + 1] = name
    end
end

print('')
print(('%d/%d specs passed'):format(#specs - #failed, #specs))
if #failed > 0 then
    print('failed: ' .. table.concat(failed, ', '))
end

os.exit(#failed == 0 and 0 or 1)
