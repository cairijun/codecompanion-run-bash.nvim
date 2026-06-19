-- Minimal init for testing with mini.test
-- Sets up runtime path and loads required dependencies

-- Add dependencies to runtime path FIRST
vim.opt.rtp:prepend("deps/mini.nvim")
vim.opt.rtp:prepend("deps/plenary.nvim")
vim.opt.rtp:prepend("deps/nvim-treesitter")
vim.opt.rtp:prepend("deps/codecompanion.nvim")
vim.opt.rtp:prepend("deps/codecompanion.nvim/tests") -- For tests.mocks.http

-- Set current project to runtime path AFTER codecompanion
vim.opt.rtp:append(vim.fn.getcwd())

-- Disable ShaDa to avoid permission errors in sandbox
vim.opt.shadafile = "NONE"

-- Setup mini.test
require("mini.test").setup()

-- Install and setup Tree-sitter
require("nvim-treesitter").setup({
  install_dir = "deps/parsers",
})

local parser_dir = "deps/parsers/parser"
local required_parsers = { "lua", "make", "markdown", "markdown_inline", "yaml", "bash" }

-- Only install parsers not already present
local to_install = {}
for _, lang in ipairs(required_parsers) do
  local parser_path = parser_dir .. "/" .. lang .. ".so"
  if vim.uv.fs_stat(parser_path) == nil then
    table.insert(to_install, lang)
  end
end

if #to_install > 0 then
  local ok, msg =
    require("nvim-treesitter").install(to_install, { summary = true, max_jobs = 10 }):wait(1800000)

  assert(ok, "Failed to install Tree-sitter parsers: " .. tostring(msg))
end
