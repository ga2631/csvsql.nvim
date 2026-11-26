local config = require("csvsql.config")
local duckdb = require("csvsql.duckdb")
local editor = require("csvsql.editor")
local installer = require("csvsql.installer")
local view = require("csvsql.view")

local M = {}

local augroup_name = "CsvSqlAutoEnable"
local warned_missing_duckdb = false

---@param buf integer
---@return boolean
function M._is_supported_buffer(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local filetypes = config.options.filetypes or { "csv", "tsv" }
  local ft = vim.bo[buf].filetype
  if vim.tbl_contains(filetypes, ft) then
    return true
  end
  -- Also match by file extension so plugins like snacks.bigfile (filetype="bigfile") do not block rendering
  local filepath = vim.api.nvim_buf_get_name(buf)
  if filepath and filepath ~= "" then
    local ext = vim.fn.fnamemodify(filepath, ":e"):lower()
    if ext ~= "" and vim.tbl_contains(filetypes, ext) then
      return true
    end
  end
  return false
end

---@param buf integer
local function maybe_auto_open(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if vim.b[buf].csvsql_raw_mode then
    return
  end
  if view.sessions_by_buf[buf] then
    return
  end
  if not M._is_supported_buffer(buf) then
    return
  end
  local filepath = vim.api.nvim_buf_get_name(buf)
  if not filepath or filepath == "" or vim.fn.filereadable(filepath) ~= 1 then
    return
  end
  if not duckdb.is_available() then
    if not warned_missing_duckdb then
      warned_missing_duckdb = true
      vim.notify(
        string.format(
          "csvsql.nvim: DuckDB not found. Opening raw file. Run :CsvSqlInstall (or install via: %s)",
          config.install_hint()
        ),
        vim.log.levels.WARN
      )
    end
    return
  end

  -- Defer slightly so Neovim finishes buffer initialization cleanly
  vim.schedule(function()
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_get_current_buf() == buf and not vim.b[buf].csvsql_raw_mode then
      view.open(filepath, buf)
    end
  end)
end

local function setup_autocmds()
  local group = vim.api.nvim_create_augroup(augroup_name, { clear = true })
  if not config.options.auto_enable then
    return
  end

  local ext_patterns = {}
  for _, ft in ipairs(config.options.filetypes or { "csv", "tsv" }) do
    table.insert(ext_patterns, "*." .. ft)
  end

  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = config.options.filetypes,
    callback = function(args)
      maybe_auto_open(args.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    pattern = ext_patterns,
    callback = function(args)
      maybe_auto_open(args.buf)
    end,
  })
end

---@param opts? table
function M.setup(opts)
  config.setup(opts)
  setup_autocmds()

  -- Handle the first buffer when lazy-loaded on FileType or BufReadPre
  if config.options.auto_enable then
    maybe_auto_open(vim.api.nvim_get_current_buf())
  end
end

---@param filepath? string
---@return CsvSqlSession|nil
function M.open(filepath)
  local raw_buf = nil
  if not filepath or filepath == "" then
    local cur = vim.api.nvim_get_current_buf()
    local existing = view.get_session(cur)
    if existing then
      filepath = existing.filepath
      raw_buf = existing.raw_buf
    else
      filepath = vim.api.nvim_buf_get_name(cur)
      raw_buf = cur
    end
  end

  if not filepath or filepath == "" then
    vim.notify("csvsql.nvim: no CSV file path specified", vim.log.levels.WARN)
    return nil
  end
  if vim.fn.filereadable(filepath) ~= 1 then
    vim.notify("csvsql.nvim: file not readable: " .. filepath, vim.log.levels.ERROR)
    return nil
  end
  if not duckdb.is_available() then
    vim.notify(
      string.format("csvsql.nvim: DuckDB not found. Run :CsvSqlInstall (or install via: %s)", config.install_hint()),
      vim.log.levels.ERROR
    )
    return nil
  end

  if raw_buf and vim.api.nvim_buf_is_valid(raw_buf) then
    vim.b[raw_buf].csvsql_raw_mode = false
  end
  return view.open(filepath, raw_buf)
end

---@param sql string
function M.query(sql)
  local session = view.get_session()
  if not session then
    session = M.open()
  end
  if not session then
    return
  end
  session:set_query(sql)
end

function M.open_editor()
  local session = view.get_session()
  if not session then
    session = M.open()
  end
  if not session then
    return
  end
  editor.toggle(session)
end

function M.reset()
  local session = view.get_session()
  if session then
    session:reset()
  end
end

function M.refresh()
  local session = view.get_session()
  if session then
    session:refresh()
  end
end

function M.toggle_watch()
  local session = view.get_session()
  if session then
    session:toggle_watch()
  end
end

function M.summarize()
  local session = view.get_session()
  if not session then
    session = M.open()
  end
  if session then
    session:summarize()
  end
end

---@param opts? { force?: boolean }
---@return boolean, string
function M.install(opts)
  return installer.install(opts)
end

function M.close()
  local session = view.get_session()
  if session then
    session:close()
  end
end

function M.toggle()
  local cur = vim.api.nvim_get_current_buf()
  local session = view.sessions_by_buf[cur]
  if session then
    session:toggle_raw()
    return
  end
  M.open()
end

return M
