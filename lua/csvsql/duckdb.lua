local config = require("csvsql.config")
local installer = require("csvsql.installer")

local M = {}

---@param filepath string
---@return string
function M.normalize_path(filepath)
  -- DuckDB accepts forward slashes across macOS, Linux, and Windows.
  local normalized = filepath:gsub("\\", "/")
  return normalized
end

---@param str string
---@return string
function M.escape_sql_string(str)
  return (str:gsub("'", "''"))
end

---@param opts? CsvSqlConfig
---@return string
function M.default_query(opts)
  opts = opts or config.options
  local tbl = opts.table_name or "data"
  if opts.default_limit and type(opts.default_limit) == "number" and opts.default_limit > 0 then
    return string.format("SELECT * FROM %s LIMIT %d", tbl, math.floor(opts.default_limit))
  end
  return string.format("SELECT * FROM %s", tbl)
end

---@param filepath string
---@param user_sql string
---@param opts? CsvSqlConfig
---@return string
function M.build_sql(filepath, user_sql, opts)
  opts = opts or config.options
  local tbl = opts.table_name or "data"
  local safe_path = M.escape_sql_string(M.normalize_path(filepath))
  local trimmed = vim.trim(user_sql or "")
  if trimmed == "" then
    trimmed = M.default_query(opts)
  end
  -- Strip trailing semicolons so we append exactly one cleanly.
  trimmed = trimmed:gsub(";+%s*$", "")

  local query_stmt = trimmed
  local should_truncate = opts.truncate
  if should_truncate == nil then
    should_truncate = config.options.truncate
  end
  local max_w = opts.max_col_width or config.options.max_col_width or 256

  -- Apply per-column ellipsis truncation for single-statement queries when enabled.
  if should_truncate and type(max_w) == "number" and max_w >= 2 and not trimmed:find(";", 1, true) then
    max_w = math.floor(max_w)
    query_stmt = string.format(
      "SELECT CASE WHEN length(CAST(COLUMNS(*) AS VARCHAR)) > %d THEN left(CAST(COLUMNS(*) AS VARCHAR), %d) || '…' ELSE CAST(COLUMNS(*) AS VARCHAR) END FROM (%s)",
      max_w,
      max_w - 1,
      trimmed
    )
  end

  return string.format(
    "CREATE OR REPLACE TEMP VIEW %s AS SELECT * FROM read_csv_auto('%s');\n%s;",
    tbl,
    safe_path,
    query_stmt
  )
end

---@param opts? CsvSqlConfig
---@return string|nil, "system"|"managed"|nil
function M.resolve_bin(opts)
  opts = opts or config.options
  local configured = opts.duckdb_bin or "duckdb"
  if vim.fn.executable(configured) == 1 then
    return configured, "system"
  end
  local managed = installer.managed_bin_path()
  if vim.fn.executable(managed) == 1 then
    return managed, "managed"
  end
  return nil, nil
end

---@param opts? CsvSqlConfig
---@return boolean
function M.is_available(opts)
  local bin = M.resolve_bin(opts)
  return bin ~= nil
end

---@param filepath string
---@param user_sql string
---@param callback fun(result: { ok: boolean, lines: string[], err?: string })
---@param opts? CsvSqlConfig
---@return vim.SystemObj|nil
function M.run_query(filepath, user_sql, callback, opts)
  opts = opts or config.options
  local bin = M.resolve_bin(opts)

  if not bin then
    vim.schedule(function()
      callback({
        ok = false,
        lines = {},
        err = string.format(
          "duckdb binary not found. Run :CsvSqlInstall or install manually: %s",
          config.install_hint()
        ),
      })
    end)
    return nil
  end

  local sql = M.build_sql(filepath, user_sql, opts)
  local mode_flag = "-" .. (opts.output_mode or "box")

  -- Pass argv directly (never via a shell) for cross-platform safety & zero injection risk.
  local cmd = { bin, mode_flag, "-c", sql }

  return vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        local err_msg = vim.trim(res.stderr or "")
        if err_msg == "" then
          err_msg = string.format("duckdb exited with code %d", res.code)
        end
        callback({ ok = false, lines = {}, err = err_msg })
        return
      end

      local stdout = (res.stdout or ""):gsub("\r\n", "\n")
      local lines = vim.split(stdout, "\n", { plain = true })
      -- Trim trailing empty line added by CLI output
      while #lines > 0 and lines[#lines] == "" do
        table.remove(lines)
      end

      if #lines == 0 then
        lines = { "(0 rows)" }
      end

      callback({ ok = true, lines = lines })
    end)
  end)
end

return M
