local config = require("csvsql.config")

local uv = vim.uv or vim.loop

local M = {}

local RELEASE_BASE_URL = "https://github.com/duckdb/duckdb/releases/latest/download"

---@return boolean
function M.is_windows()
  return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

---@return string
function M.bin_dir()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "csvsql", "bin")
end

---@return string
function M.managed_bin_path()
  local name = M.is_windows() and "duckdb.exe" or "duckdb"
  return vim.fs.joinpath(M.bin_dir(), name)
end

---@param uname? { sysname?: string, machine?: string }
---@return { os: string, arch: string }|nil, string|nil
function M.detect_platform(uname)
  local info = uname or (uv and uv.os_uname and uv.os_uname()) or {}
  local sys = (info.sysname or ""):lower()
  local machine = (info.machine or ""):lower()

  local is_arm64 = (machine == "arm64" or machine == "aarch64")
  local is_x64 = (machine == "x86_64" or machine == "amd64" or machine == "x64")

  if sys == "darwin" then
    return { os = "osx", arch = "universal", raw_arch = is_arm64 and "arm64" or "amd64" }, nil
  elseif sys == "linux" then
    if is_arm64 then
      return { os = "linux", arch = "arm64" }, nil
    elseif is_x64 then
      return { os = "linux", arch = "amd64" }, nil
    end
    return nil, string.format("Unsupported Linux architecture: %s", tostring(info.machine))
  elseif sys:match("windows") or sys:match("mingw") or sys:match("msys") or sys:match("cygwin") then
    if is_arm64 then
      return { os = "windows", arch = "arm64" }, nil
    elseif is_x64 then
      return { os = "windows", arch = "amd64" }, nil
    end
    return nil, string.format("Unsupported Windows architecture: %s", tostring(info.machine))
  end

  return nil, string.format("Unsupported OS: %s (%s)", tostring(info.sysname), tostring(info.machine))
end

---@param platform { os: string, arch: string, raw_arch?: string }
---@return { filename: string, url: string, format: "zip"|"tar.gz" }[]
function M.candidate_assets(platform)
  local assets = {}
  local function add(filename, format)
    table.insert(assets, {
      filename = filename,
      url = string.format("%s/%s", RELEASE_BASE_URL, filename),
      format = format,
    })
  end

  -- DuckDB official release asset naming (supports both .zip and .tar.gz conventions)
  add(string.format("duckdb_cli-%s-%s.zip", platform.os, platform.arch), "zip")
  add(string.format("duckdb-cli-%s-%s.tar.gz", platform.os, platform.arch), "tar.gz")

  if platform.os == "osx" and platform.raw_arch then
    add(string.format("duckdb-cli-osx-%s.tar.gz", platform.raw_arch), "tar.gz")
    add(string.format("duckdb_cli-osx-%s.zip", platform.raw_arch), "zip")
  end

  return assets
end

---@param archive_path string
---@param format "zip"|"tar.gz"
---@param dest_dir string
---@return boolean, string|nil
local function extract_archive(archive_path, format, dest_dir)
  local cmds = {}
  if format == "tar.gz" then
    table.insert(cmds, { "tar", "-xzf", archive_path, "-C", dest_dir })
  else
    if M.is_windows() then
      table.insert(cmds, { "tar", "-xf", archive_path, "-C", dest_dir })
      table.insert(cmds, {
        "powershell",
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        string.format(
          "Expand-Archive -LiteralPath '%s' -DestinationPath '%s' -Force",
          archive_path:gsub("'", "''"),
          dest_dir:gsub("'", "''")
        ),
      })
    else
      if vim.fn.executable("unzip") == 1 then
        table.insert(cmds, { "unzip", "-o", "-q", archive_path, "-d", dest_dir })
      end
      if vim.fn.executable("tar") == 1 then
        table.insert(cmds, { "tar", "-xf", archive_path, "-C", dest_dir })
      end
    end
  end

  if #cmds == 0 then
    return false, "No extraction tool found (install unzip or tar)"
  end

  local last_err = nil
  for _, cmd in ipairs(cmds) do
    local res = vim.system(cmd, { text = true }):wait()
    if res.code == 0 then
      return true, nil
    end
    last_err = vim.trim(res.stderr or "")
  end

  return false, last_err ~= "" and last_err or "Failed to extract DuckDB archive"
end

---@param opts? { force?: boolean }
---@return boolean, string
function M.install(opts)
  opts = opts or {}
  local managed = M.managed_bin_path()
  local configured = config.options.duckdb_bin or "duckdb"

  if not opts.force then
    if vim.fn.executable(configured) == 1 then
      local msg = string.format("csvsql.nvim: DuckDB already available on PATH (%s). Use :CsvSqlInstall! to install managed copy.", configured)
      vim.notify(msg, vim.log.levels.INFO)
      return true, msg
    end
    if vim.fn.executable(managed) == 1 then
      local msg = string.format("csvsql.nvim: Managed DuckDB already installed at %s. Use :CsvSqlInstall! to reinstall.", managed)
      vim.notify(msg, vim.log.levels.INFO)
      return true, msg
    end
  end

  if vim.fn.executable("curl") ~= 1 then
    local msg = "csvsql.nvim: 'curl' is required to auto-install DuckDB. Manual install: " .. config.install_hint()
    vim.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end

  local platform, plat_err = M.detect_platform()
  if not platform then
    local msg = "csvsql.nvim: " .. tostring(plat_err) .. ". Manual install: " .. config.install_hint()
    vim.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end

  local dest_dir = M.bin_dir()
  vim.fn.mkdir(dest_dir, "p")

  local assets = M.candidate_assets(platform)
  local downloaded_archive = nil
  local downloaded_format = nil
  local last_dl_err = nil

  vim.notify("csvsql.nvim: Downloading DuckDB CLI for " .. platform.os .. "-" .. platform.arch .. "...", vim.log.levels.INFO)

  for _, asset in ipairs(assets) do
    local tmp_path = vim.fs.joinpath(dest_dir, ".tmp-" .. asset.filename)
    local res = vim.system({ "curl", "-fsSL", "-o", tmp_path, asset.url }, { text = true }):wait()
    if res.code == 0 and vim.fn.filereadable(tmp_path) == 1 then
      downloaded_archive = tmp_path
      downloaded_format = asset.format
      break
    else
      pcall(vim.fn.delete, tmp_path)
      last_dl_err = vim.trim(res.stderr or ("curl exited with code " .. tostring(res.code)))
    end
  end

  if not downloaded_archive or not downloaded_format then
    local msg = string.format(
      "csvsql.nvim: Failed to download DuckDB CLI (%s). Manual install: %s",
      tostring(last_dl_err),
      config.install_hint()
    )
    vim.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end

  local ok_extract, extract_err = extract_archive(downloaded_archive, downloaded_format, dest_dir)
  pcall(vim.fn.delete, downloaded_archive)

  if not ok_extract then
    local msg = "csvsql.nvim: Failed to extract DuckDB archive: " .. tostring(extract_err)
    vim.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end

  if not M.is_windows() and uv and uv.fs_chmod then
    pcall(uv.fs_chmod, managed, tonumber("755", 8))
  end

  if vim.fn.executable(managed) ~= 1 then
    local msg = "csvsql.nvim: Extraction completed but DuckDB binary not found at " .. managed
    vim.notify(msg, vim.log.levels.ERROR)
    return false, msg
  end

  local ver_res = vim.system({ managed, "--version" }, { text = true }):wait()
  local ver = ver_res.code == 0 and vim.trim(ver_res.stdout or "") or "installed"
  local ok_msg = string.format("csvsql.nvim: Installed DuckDB (%s) to %s", ver, managed)
  vim.notify(ok_msg, vim.log.levels.INFO)
  return true, ok_msg
end

return M
