-- Public API against the real node/MathJax renderer: identical requests must
-- reuse the processor's content cache, invalid TeX must report an error, and a
-- failed render must not poison the next one.
--
-- Only the Kitty transport is stubbed: there is no TTY headless.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h:h')
local t = dofile(root .. '/tests/helper.lua')
t.bootstrap()

local ok_deps, reason = t.has_render_deps(root)
if not ok_deps then
    t.skip('render API', reason)
    t.finish()
end

local mdmath = require'mdmath'
mdmath.setup({})
t.stub_image()

--- Renders through the public API and waits for the callback.
local function render(tex, opts)
    local image, err
    mdmath.render(tex, opts, function(i, e)
        image, err = i, e
    end)
    t.wait_for(function()
        return image ~= nil or err ~= nil
    end, 60000)
    return image, err
end

local first = render('a^2 + b^2')
t.ok(first ~= nil, 'first render returns an image')
if not first then
    t.finish()
end
t.ok(first.path:match('%.png$') ~= nil, 'image path points to a PNG')
t.ok(first.rows >= 1 and first.cols >= 1, 'image has cell dimensions')

local second = render('a^2 + b^2')
t.ok(second ~= nil, 'identical request returns an image')
t.eq(second and second.path, first.path, 'identical requests reuse the cached PNG')

local other = render('a^3 + c')
t.ok(other ~= nil, 'different equation returns an image')
t.ok(other and other.path ~= first.path, 'different equations produce different PNGs')

local failed, err = render('\\frac{')
t.eq(failed, nil, 'invalid TeX returns no image')
t.ok(err ~= nil and #err > 0, 'invalid TeX returns an error message')

local recovered = render('a^2 + b^2')
t.ok(recovered ~= nil, 'a valid render still works after a failure')
t.eq(recovered and recovered.path, first.path, 'recovery hits the cache again')

t.finish()
