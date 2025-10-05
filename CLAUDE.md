# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

mdmath.nvim is a Neovim plugin that renders LaTeX math equations inline in Markdown files using the Kitty Graphics Protocol. The plugin combines Lua (Neovim side) with Node.js (equation processing) to provide real-time math rendering.

## Architecture

The plugin has a dual-language architecture:

### Lua Components (lua/mdmath/)
- **init.lua**: Main plugin entry point, setup and command handlers
- **overlay.lua**: Core rendering system managing equation overlays in buffers
- **Processor.lua**: Lua-side process manager for Node.js communication
- **Equation.lua**: Equation state management and rendering logic
- **Image.lua**: Kitty Graphics Protocol image handling
- **build.lua**: Build system for Node.js dependencies
- **config.lua**: Plugin configuration management
- **tracker.lua**: File change tracking and update management

### Node.js Components (mdmath-js/src/)
- **processor.js**: Main Node.js process handling MathJax rendering
- **magick.js**: ImageMagick integration for SVG-to-PNG conversion
- **reader.js**: Stdin/stdout communication with Neovim process

## Development Commands

### Build System
```bash
# Build Node.js dependencies (equivalent to :MdMath build)
cd mdmath-js && npm install

# Manual build from Neovim
:MdMath build
```

### Plugin Commands
```vim
:MdMath enable   " Enable for current buffer
:MdMath disable  " Disable for current buffer  
:MdMath clear    " Refresh all equations
:MdMath build    " Build/rebuild Node.js server
```

### Testing Setup
The plugin requires specific system dependencies:
- Node.js and npm
- ImageMagick v6/v7
- rsvg-convert (librsvg)
- Terminal with Kitty Graphics Protocol + Unicode Placeholders support

## Key Implementation Details

### Process Architecture
- Lua spawns a persistent Node.js process (`mdmath-js/src/processor.js`)
- Communication via stdin/stdout using a custom protocol
- Images cached in `/tmp/nvim-mdmath-{random}/`
- Each equation gets a unique ID for tracking

### Rendering Pipeline
1. TreeSitter parses markdown_inline for math expressions
2. Equations sent to Node.js process via Processor.lua
3. Node.js renders with MathJax, converts SVG→PNG via ImageMagick
4. Images displayed using Kitty Graphics Protocol via Image.lua
5. Overlay.lua manages positioning and buffer updates

### Configuration System
Plugin uses a centralized config in `config.lua` with options for:
- Filetypes, colors, scaling, update intervals
- Dynamic sizing, anticonceal behavior
- Internal vs display scaling separation