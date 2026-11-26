local duckdb = require("csvsql.duckdb")

local M = {}

function M.check()
  vim.health.start("csvsql.nvim")

  -- 1. Neovim version check
  if vim.fn.has("nvim-0.10") == 1 then
    local v = vim.version()
    vim.health.ok(string.format("Neovim %d.%d.%d (>= 0.10 required)", v.major, v.minor, v.patch))
  else
    vim.health.error("Neovim >= 0.10 is required (for vim.system and vim.uv)")
  end

  -- 2. DuckDB CLI check (system PATH or plugin-managed binary)
  local bin, source = duckdb.resolve_bin()
  if bin then
    local res = vim.system({ bin, "--version" }, { text = true }):wait()
    if res.code == 0 then
      local ver = vim.trim(res.stdout or "")
      vim.health.ok(string.format("DuckDB CLI found [%s] (%s): %s", source, bin, ver))
    else
      vim.health.warn(string.format("DuckDB binary '%s' is executable but returned code %d", bin, res.code))
    end
  else
    vim.health.error("DuckDB CLI not found (neither on PATH nor plugin-managed)", {
      "Automatic (all OSes): Run :CsvSqlInstall inside Neovim",
      "macOS:   brew install duckdb",
      "Linux:   curl https://install.duckdb.org | sh  (or pacman -S duckdb / nix-env -iA nixpkgs.duckdb)",
      "Windows: winget install DuckDB.cli  (or: scoop install duckdb / choco install duckdb)",
    })
  end

  -- 3. libuv fs_event check
  local uv = vim.uv or vim.loop
  if uv and type(uv.new_fs_event) == "function" then
    vim.health.ok("libuv file watcher (vim.uv.new_fs_event) available")
  else
    vim.health.warn("libuv file watcher unavailable; real-time auto-refresh will not work")
  end
end

return M
