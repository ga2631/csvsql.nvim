-- Minimal clean Neovim init for recording the csvsql.nvim demo GIF
vim.opt.termguicolors = true
vim.opt.background = "dark"
vim.opt.cursorline = true
vim.opt.laststatus = 2
vim.opt.cmdheight = 1
vim.opt.showmode = true

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("runtime plugin/csvsql.lua")

-- Clean GitHub Dark-inspired highlights for crisp demo visuals
vim.api.nvim_set_hl(0, "Normal", { fg = "#e6edf3", bg = "#0d1117" })
vim.api.nvim_set_hl(0, "CursorLine", { bg = "#1f2937" })
vim.api.nvim_set_hl(0, "Title", { fg = "#58a6ff", bold = true })
vim.api.nvim_set_hl(0, "Comment", { fg = "#8b949e" })
vim.api.nvim_set_hl(0, "NonText", { fg = "#30363d" })
vim.api.nvim_set_hl(0, "CsvSqlRowEven", { bg = "#1b222c" })
vim.api.nvim_set_hl(0, "StatusLine", { fg = "#e6edf3", bg = "#161b22" })

require("csvsql").setup({
  max_col_width = 48,
  sticky_header = true,
  zebra_striping = true,
  editor_height = 6,
})
