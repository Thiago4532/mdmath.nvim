# ✨ mdmath.nvim

A Markdown equation previewer inside Neovim, using Kitty Graphics Protocol.

https://github.com/user-attachments/assets/bcfab0d2-60fb-4e8a-9402-2be62a5504f6

## Requirements
  - Neovim version `>=0.10.0`
  - Tree-sitter parser `markdown_inline`

### System requirements
  - NodeJS
  - `npm`
  - ImageMagick v6/v7
  - `rsvg-convert` (from librsvg)
  - Linux/MacOS (not tested in MacOS, please open an issue if you are able to test it)

You also need a terminal emulator that supports [Kitty Graphics Protocol#Unicode Placeholders](https://sw.kovidgoyal.net/kitty/graphics-protocol/#unicode-placeholders), the following terminals were tested.
  - [x] Kitty `>=0.28.0`
  - [ ] Konsole (missing support for Unicode Placeholders)
  - [ ] WezTerm (missing support for Unicode Placeholders)

After some refactoring, I want to implement a fallback for terminals that support Kitty Graphics Protocol but doesn't support Unicode Placeholders.

### Installation

>[!NOTE]
> If you have manually installed the parser then you don't need `nvim-treesitter`. Just make sure the parsers are loaded before this plugin.

### lazy.nvim

```lua
{
    'Thiago4532/mdmath.nvim',
    dependencies = {
        'nvim-treesitter/nvim-treesitter',
    },
    opts = {...}

    -- The build is already done by default in lazy.nvim, so you don't need
    -- the next line, but you can use the command `:MdMath build` to rebuild
    -- if the build fails for some reason.
    -- build = ':MdMath build'
},
```

### Other plugin managers

Just make sure to have the treesitter parser `markdown-inline` loaded before the plugin, also you have to build the plugin before using it, you can build it by running `:MdMath build` or `require'mdmath'.build()`.

## Configuration

Here is the table of configurations, and the default values:

```lua
opts = {
    -- Filetypes that the plugin will be enabled by default.
    filetypes = {'markdown'},
    -- Color of the equation, can be a highlight group or a hex color.
    -- Examples: 'Normal', '#ff0000'
    foreground = 'Normal',
    -- Hide the text when the equation is under the cursor.
    anticonceal = true,
    -- Hide the text when in the Insert Mode.
    hide_on_insert = true,
    -- Enable dynamic size for non-inline equations.
    dynamic = true,
    -- Configure the scale of dynamic-rendered equations.
    dynamic_scale = 1.0,
    -- Interval between updates (milliseconds).
    update_interval = 400,

    -- Internal scale of the equation images, increase to prevent blurry images when increasing terminal
    -- font, high values may produce aliased images.
    -- WARNING: This do not affect how the images are displayed, only how many pixels are used to render them.
    --          See `dynamic_scale` to modify the displayed size.
    internal_scale = 1.0,

    -- How the rendered PNG is sent to the terminal:
    --   'auto'   -> 'file' (recommended)
    --   'file'   -> the terminal reads the PNG from disk (Kitty protocol `t=f`)
    --   'direct' -> the PNG is base64-chunked over stdout (`t=d`); only for
    --               terminals that cannot read a file path. Large writes can be
    --               split by Neovim's own redraws, which corrupts the sequence
    --               and prints the payload as text.
    transfer = 'auto',
}
```

## Usage

Currently, it only supports rendering the image inline, features like rendering at a floating window will be available soon.
  - `:MdMath enable`: Enable the plugin for the current buffer
  - `:MdMath disable`: Disable the plugin for the current buffer
  - `:MdMath clear`: Refresh all equations
  - `:MdMath build`: Build the node.js server

If you are using TMUX, remember to enable `allow-passthrough` in your `~/.tmux.conf`.

## Development

```sh
make test    # headless Lua specs (one Neovim process per spec) + node IPC/unit tests
make bench   # viewport scan cost on a synthetic document
```

The render spec needs `node`, `rsvg-convert`, ImageMagick and `mdmath-js/node_modules`
(`:MdMath build`). Without them it is skipped, not failed. Terminal capabilities are probed
with `python3 tests/manual/kitty-probe.py`; the manual checklist is
`tests/manual/mdmath-test.md`.

The Lua client and the node processor share a byte-oriented wire format. If you change any
field order or meaning, bump `PROTOCOL_VERSION` in both `lua/mdmath/Processor.lua` and
`mdmath-js/src/processor.js` — the processor refuses to start on a mismatch.

## Looking to the future!

The plugin is currently at alpha, many features are planned for the next versions, here are some of the planned features, also you have any suggestions, feel free to open an issue:
  - [ ] Support Kitty Graphics Protocol without Unicode Placeholders.
  - [ ] An API to generate equation images.
  - [ ] Render in floating windows
  - [ ] Render out-of-line
  - [x] Dynamic width and height
  - [ ] Refactoring: LuaCATS annotations
  - [ ] Documentation
  - [ ] `:checkhealth`
