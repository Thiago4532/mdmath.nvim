NVIM ?= nvim
NODE ?= node

.PHONY: test test-lua test-js bench

# Full regression suite: headless Lua specs + node IPC/unit tests.
test: test-lua test-js

# Each spec runs in its own Neovim process (options are frozen after setup).
test-lua:
	$(NVIM) --headless --clean -l tests/runner.lua

test-js:
	$(NODE) --test tests/js/*.test.mjs

# Viewport scan cost on a synthetic document (not a pass/fail gate).
bench:
	$(NVIM) --headless --clean -l tests/bench/viewport.lua
