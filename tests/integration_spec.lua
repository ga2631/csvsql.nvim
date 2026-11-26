local T = _G.CsvSqlTest
local csvsql = require("csvsql")
local duckdb = require("csvsql.duckdb")

io.write("Running csvsql.nvim integration tests...\n")

if not duckdb.is_available() then
  io.write("  SKIP  duckdb binary not found on PATH — install duckdb to run integration tests.\n")
  T.finish()
  return
end

T.test("opens CSV, runs SQL query, and live-updates on disk change", function()
  csvsql.setup({ debounce_ms = 50 })

  local tmp = vim.fn.tempname() .. ".csv"
  vim.fn.writefile({
    "id,name,score",
    "1,alice,90",
    "2,bob,40",
  }, tmp)

  local session = csvsql.open(tmp)
  T.assert_true(session ~= nil, "session should be created")

  local loaded = vim.wait(3000, function()
    local lines = vim.api.nvim_buf_get_lines(session.view_buf, 0, -1, false)
    return table.concat(lines, "\n"):find("alice", 1, true) ~= nil
  end, 30)
  T.assert_true(loaded, "initial table should render alice")

  -- Run SQL filter
  csvsql.query("SELECT name FROM data WHERE score > 50")
  local filtered = vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(session.view_buf, 0, -1, false), "\n")
    return text:find("alice", 1, true) ~= nil and text:find("bob", 1, true) == nil
  end, 30)
  T.assert_true(filtered, "filtered query should show alice and exclude bob")

  -- Modify CSV on disk and verify live update
  vim.fn.writefile({
    "id,name,score",
    "1,alice,90",
    "2,bob,40",
    "3,charlie,99",
  }, tmp)

  local updated = vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(session.view_buf, 0, -1, false), "\n")
    return text:find("charlie", 1, true) ~= nil
  end, 30)
  T.assert_true(updated, "live watcher should re-run SQL and render charlie")

  session:destroy()
  vim.fn.delete(tmp)
end)

T.test("truncates >256 char cells by default and toggles full & wrap modes", function()
  csvsql.setup({ debounce_ms = 50, truncate = true, max_col_width = 256, wrap = false })

  local long_val = string.rep("x", 300)
  local tmp = vim.fn.tempname() .. ".csv"
  vim.fn.writefile({
    "id,payload",
    "1," .. long_val,
  }, tmp)

  local session = csvsql.open(tmp)
  T.assert_true(session ~= nil, "session should be created")
  T.assert_eq(session.truncate, true)
  T.assert_eq(session.wrap, false)
  T.assert_eq(vim.wo[vim.api.nvim_get_current_win()].wrap, false)

  -- Default mode: truncated to 255 'x' + '…' (full 300-char string should NOT appear)
  local expected_trunc = string.rep("x", 255) .. "…"
  local trunc_ok = vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(session.view_buf, 0, -1, false), "\n")
    return text:find(expected_trunc, 1, true) ~= nil and text:find(long_val, 1, true) == nil
  end, 30)
  T.assert_true(trunc_ok, "default mode should ellipsis cells longer than 256 chars")

  -- Toggle to full mode
  session:toggle_truncate()
  T.assert_eq(session.truncate, false)
  local full_ok = vim.wait(3000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(session.view_buf, 0, -1, false), "\n")
    return text:find(long_val, 1, true) ~= nil and text:find("[FULL]", 1, true) ~= nil
  end, 30)
  T.assert_true(full_ok, "full mode should display all 300 chars")

  -- Toggle wrap mode
  session:toggle_wrap()
  T.assert_eq(session.wrap, true)
  T.assert_eq(vim.wo[vim.api.nvim_get_current_win()].wrap, true)
  local header = vim.api.nvim_buf_get_lines(session.view_buf, 0, 1, false)[1] or ""
  T.assert_true(header:find("[WRAP]", 1, true) ~= nil, "header should show [WRAP]")

  session:destroy()
  vim.fn.delete(tmp)
end)

T.finish()
