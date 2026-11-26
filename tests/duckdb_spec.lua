local T = _G.CsvSqlTest
local config = require("csvsql.config")
local duckdb = require("csvsql.duckdb")
local installer = require("csvsql.installer")
local watcher_mod = require("csvsql.watcher")

io.write("Running csvsql.nvim unit tests...\n")

T.test("config.setup merges defaults and validates invalid values", function()
  local opts = config.setup({ default_limit = 50, output_mode = "markdown", table_name = "sales" })
  T.assert_eq(opts.default_limit, 50)
  T.assert_eq(opts.output_mode, "markdown")
  T.assert_eq(opts.table_name, "sales")
  T.assert_eq(opts.live_watch, true)

  -- Invalid output_mode and table_name fall back safely
  local fallback = config.setup({ output_mode = "invalid_mode", table_name = "bad;DROP TABLE" })
  T.assert_eq(fallback.output_mode, "box")
  T.assert_eq(fallback.table_name, "data")

  -- Restore defaults
  config.setup({})
end)

T.test("config.install_hint returns non-empty OS-appropriate command", function()
  local hint = config.install_hint()
  T.assert_true(type(hint) == "string" and #hint > 0)
end)

T.test("duckdb.normalize_path converts Windows backslashes to forward slashes", function()
  T.assert_eq(duckdb.normalize_path([[C:\Users\Alice Smith\my data.csv]]), "C:/Users/Alice Smith/my data.csv")
  T.assert_eq(duckdb.normalize_path("/tmp/test.csv"), "/tmp/test.csv")
end)

T.test("duckdb.escape_sql_string escapes single quotes", function()
  T.assert_eq(duckdb.escape_sql_string("/tmp/o'brien's.csv"), "/tmp/o''brien''s.csv")
end)

T.test("duckdb.default_query respects default_limit and table_name", function()
  T.assert_eq(duckdb.default_query({ table_name = "data", default_limit = 1000 }), "SELECT * FROM data LIMIT 1000")
  T.assert_eq(duckdb.default_query({ table_name = "logs", default_limit = false }), "SELECT * FROM logs")
end)

T.test("duckdb.build_sql wraps path safely and strips trailing semicolons", function()
  local sql = duckdb.build_sql(
    [[C:\tmp\o'neil data.csv]],
    "  SELECT id, name FROM data WHERE id > 10;;  ",
    { table_name = "data", default_limit = 1000 }
  )
  T.assert_eq(
    sql,
    "CREATE OR REPLACE TEMP VIEW data AS SELECT * FROM read_csv_auto('C:/tmp/o''neil data.csv');\nSELECT id, name FROM data WHERE id > 10;"
  )
end)

T.test("duckdb.build_sql supports user CTEs and empty SQL fallback", function()
  local cte_sql = duckdb.build_sql("/tmp/a.csv", "WITH top AS (SELECT * FROM data) SELECT * FROM top", {
    table_name = "data",
    default_limit = 100,
  })
  T.assert_true(cte_sql:find("CREATE OR REPLACE TEMP VIEW data", 1, true) ~= nil)
  T.assert_true(cte_sql:find("WITH top AS", 1, true) ~= nil)

  local empty_sql = duckdb.build_sql("/tmp/a.csv", "   ", { table_name = "data", default_limit = 25 })
  T.assert_true(empty_sql:find("SELECT * FROM data LIMIT 25;", 1, true) ~= nil)
end)

T.test("watcher detects real-time file modification and cleans up on stop", function()
  local tmp = vim.fn.tempname() .. ".csv"
  vim.fn.writefile({ "id,name", "1,alice" }, tmp)

  local triggered = 0
  local w = watcher_mod.new(tmp, 50, function()
    triggered = triggered + 1
  end)
  T.assert_true(w:start(), "watcher should start")
  T.assert_true(w.active, "watcher should be active")

  -- Modify file on disk
  vim.fn.writefile({ "id,name", "1,alice", "2,bob" }, tmp)

  local ok = vim.wait(1000, function()
    return triggered >= 1
  end, 20)
  w:stop()
  vim.fn.delete(tmp)

  T.assert_true(ok, "watcher callback should fire after file change")
  T.assert_eq(w.active, false)
end)

T.test("plugin commands and health module load cleanly", function()
  local cmds = vim.api.nvim_get_commands({})
  T.assert_true(cmds.CsvSql ~= nil, ":CsvSql should be registered")
  T.assert_true(cmds.CsvSqlOpen ~= nil, ":CsvSqlOpen should be registered")
  T.assert_true(cmds.CsvSqlEditor ~= nil, ":CsvSqlEditor should be registered")
  T.assert_true(cmds.CsvSqlToggle ~= nil, ":CsvSqlToggle should be registered")
  T.assert_true(cmds.CsvSqlReset ~= nil, ":CsvSqlReset should be registered")
  T.assert_true(cmds.CsvSqlWatch ~= nil, ":CsvSqlWatch should be registered")
  T.assert_true(cmds.CsvSqlSummarize ~= nil, ":CsvSqlSummarize should be registered")
  T.assert_true(cmds.CsvSqlInstall ~= nil, ":CsvSqlInstall should be registered")
  T.assert_true(cmds.CsvSqlClose ~= nil, ":CsvSqlClose should be registered")

  local health = require("csvsql.health")
  T.assert_true(type(health.check) == "function")
end)

T.test("installer detects macOS, Linux, and Windows architectures accurately", function()
  local mac = installer.detect_platform({ sysname = "Darwin", machine = "arm64" })
  T.assert_eq(mac.os, "osx")
  T.assert_eq(mac.arch, "universal")
  T.assert_eq(mac.raw_arch, "arm64")

  local linux_x64 = installer.detect_platform({ sysname = "Linux", machine = "x86_64" })
  T.assert_eq(linux_x64.os, "linux")
  T.assert_eq(linux_x64.arch, "amd64")

  local linux_arm = installer.detect_platform({ sysname = "Linux", machine = "aarch64" })
  T.assert_eq(linux_arm.os, "linux")
  T.assert_eq(linux_arm.arch, "arm64")

  local win_x64 = installer.detect_platform({ sysname = "Windows_NT", machine = "AMD64" })
  T.assert_eq(win_x64.os, "windows")
  T.assert_eq(win_x64.arch, "amd64")

  local unsupported, err = installer.detect_platform({ sysname = "Plan9", machine = "mips" })
  T.assert_eq(unsupported, nil)
  T.assert_true(type(err) == "string" and #err > 0)
end)

T.test("installer generates valid release asset candidates and managed path", function()
  local assets = installer.candidate_assets({ os = "linux", arch = "amd64" })
  T.assert_true(#assets >= 2)
  T.assert_eq(assets[1].filename, "duckdb_cli-linux-amd64.zip")
  T.assert_eq(assets[2].filename, "duckdb-cli-linux-amd64.tar.gz")
  T.assert_true(assets[1].url:find("https://github.com/duckdb/duckdb/releases/latest/download/", 1, true) == 1)

  local managed = installer.managed_bin_path()
  T.assert_true(managed:find("csvsql", 1, true) ~= nil)
  T.assert_true(managed:find("duckdb", 1, true) ~= nil)
end)

T.test("auto-enable detects .csv files even when filetype is overridden to bigfile", function()
  local csvsql = require("csvsql")
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "/tmp/huge_benchmark.csv")
  vim.bo[buf].filetype = "bigfile"

  T.assert_true(csvsql._is_supported_buffer(buf), ".csv with filetype=bigfile should still be supported")

  local non_csv = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(non_csv, "/tmp/notes.txt")
  vim.bo[non_csv].filetype = "bigfile"

  T.assert_eq(csvsql._is_supported_buffer(non_csv), false, ".txt with filetype=bigfile should not match")

  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_buf_delete(non_csv, { force = true })
end)

T.test("session:close wipes viewer buffer without closing the window", function()
  local view = require("csvsql.view")
  local tmp = vim.fn.tempname() .. ".csv"
  vim.fn.writefile({ "id,name", "1,alice" }, tmp)

  local raw_buf = vim.fn.bufadd(tmp)
  vim.fn.bufload(raw_buf)
  local win_before = vim.api.nvim_get_current_win()
  local session = view.open(tmp, raw_buf)
  local view_buf = session.view_buf

  T.assert_eq(vim.api.nvim_win_get_buf(win_before), view_buf)
  session:close()

  T.assert_true(vim.api.nvim_win_is_valid(win_before), "window should remain open")
  T.assert_eq(vim.api.nvim_buf_is_valid(view_buf), false, "viewer buffer should be wiped")
  T.assert_true(vim.api.nvim_win_get_buf(win_before) ~= view_buf, "window should show fallback buffer")

  vim.fn.delete(tmp)
end)

T.finish()
