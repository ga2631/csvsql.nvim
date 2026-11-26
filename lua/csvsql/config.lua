---@class CsvSqlKeymaps
---@field editor string|false Toggle the SQL scratch editor split
---@field prompt string|false Open quick single-line SQL prompt
---@field reset string|false Reset query to default SELECT *
---@field refresh string|false Manually refresh the table
---@field toggle_raw string|false Toggle between table view and raw CSV
---@field toggle_watch string|false Toggle live file watching
---@field summarize string|false Run SUMMARIZE data for quick column stats

---@class CsvSqlConfig
---@field auto_enable boolean Automatically render CSV/TSV files as read-only tables on open
---@field filetypes string[] Filetypes that trigger auto_enable
---@field duckdb_bin string Path or binary name for DuckDB CLI
---@field table_name string Virtual SQL view name representing the current CSV file
---@field default_limit integer|false Row limit applied to the default query (false to disable)
---@field output_mode "box"|"markdown"|"table"|"column" DuckDB table output mode
---@field debounce_ms integer Debounce interval (ms) for real-time file watcher updates
---@field live_watch boolean Enable real-time file watching by default
---@field editor_height integer Height (lines) of the SQL scratch split
---@field show_header boolean Show status/query header banner at the top of the table buffer
---@field keymaps CsvSqlKeymaps Buffer-local keymaps for the table view

local M = {}

---@type CsvSqlConfig
M.defaults = {
  auto_enable = true,
  filetypes = { "csv", "tsv" },
  duckdb_bin = "duckdb",
  table_name = "data",
  default_limit = 1000,
  output_mode = "box",
  debounce_ms = 200,
  live_watch = true,
  editor_height = 8,
  show_header = true,
  keymaps = {
    editor = "gs",
    prompt = "gq",
    reset = "gR",
    refresh = "r",
    toggle_raw = "gr",
    toggle_watch = "gw",
    summarize = "gS",
  },
}

---@type CsvSqlConfig
M.options = vim.deepcopy(M.defaults)

local VALID_OUTPUT_MODES = {
  box = true,
  markdown = true,
  table = true,
  column = true,
}

---@param opts? table
---@return CsvSqlConfig
function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})

  if not VALID_OUTPUT_MODES[merged.output_mode] then
    vim.notify(
      string.format("csvsql.nvim: invalid output_mode '%s', falling back to 'box'", tostring(merged.output_mode)),
      vim.log.levels.WARN
    )
    merged.output_mode = "box"
  end

  if type(merged.table_name) ~= "string" or not merged.table_name:match("^[%a_][%w_]*$") then
    vim.notify(
      string.format("csvsql.nvim: invalid table_name '%s', falling back to 'data'", tostring(merged.table_name)),
      vim.log.levels.WARN
    )
    merged.table_name = "data"
  end

  if type(merged.debounce_ms) ~= "number" or merged.debounce_ms < 0 then
    merged.debounce_ms = M.defaults.debounce_ms
  end

  M.options = merged
  return M.options
end

---@return string
function M.install_hint()
  if vim.fn.has("mac") == 1 then
    return "brew install duckdb"
  elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    return "winget install DuckDB.cli  (or: scoop install duckdb)"
  else
    return "curl https://install.duckdb.org | sh  (or your distro package manager)"
  end
end

return M
