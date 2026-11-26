if vim.g.loaded_csvsql == 1 then
  return
end
vim.g.loaded_csvsql = 1

local function csvsql()
  return require("csvsql")
end

vim.api.nvim_create_user_command("CsvSql", function(opts)
  if opts.args and vim.trim(opts.args) ~= "" then
    csvsql().query(opts.args)
  else
    csvsql().open_editor()
  end
end, {
  nargs = "*",
  desc = "Run a SQL query on the current CSV file (or open the SQL editor if empty)",
})

vim.api.nvim_create_user_command("CsvSqlOpen", function(opts)
  csvsql().open(opts.args ~= "" and opts.args or nil)
end, {
  nargs = "?",
  complete = "file",
  desc = "Open a CSV/TSV file in csvsql live table view",
})

vim.api.nvim_create_user_command("CsvSqlEditor", function()
  csvsql().open_editor()
end, {
  desc = "Toggle the multi-line SQL scratch editor split",
})

vim.api.nvim_create_user_command("CsvSqlToggle", function()
  csvsql().toggle()
end, {
  desc = "Toggle between rendered table view and raw CSV buffer",
})

vim.api.nvim_create_user_command("CsvSqlReset", function()
  csvsql().reset()
end, {
  desc = "Reset SQL query back to default SELECT *",
})

vim.api.nvim_create_user_command("CsvSqlRefresh", function()
  csvsql().refresh()
end, {
  desc = "Manually refresh the rendered CSV table",
})

vim.api.nvim_create_user_command("CsvSqlWatch", function()
  csvsql().toggle_watch()
end, {
  desc = "Toggle real-time file watching for the current CSV view",
})

vim.api.nvim_create_user_command("CsvSqlSummarize", function()
  csvsql().summarize()
end, {
  desc = "Run SUMMARIZE on the current CSV file for column statistics",
})

vim.api.nvim_create_user_command("CsvSqlInstall", function(opts)
  csvsql().install({ force = opts.bang })
end, {
  bang = true,
  desc = "Install (or reinstall with !) the DuckDB CLI binary for csvsql.nvim",
})

vim.api.nvim_create_user_command("CsvSqlClose", function()
  csvsql().close()
end, {
  desc = "Close only the csvsql viewer buffer without quitting Neovim",
})

vim.api.nvim_create_user_command("CsvSqlTruncate", function()
  csvsql().toggle_truncate()
end, {
  desc = "Toggle column ellipsis truncation (max_col_width) vs full cell values",
})

vim.api.nvim_create_user_command("CsvSqlWrap", function()
  csvsql().toggle_wrap()
end, {
  desc = "Toggle viewbox line wrapping in the csvsql table viewer",
})
