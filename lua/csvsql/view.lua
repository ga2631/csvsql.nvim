local config = require("csvsql.config")
local duckdb = require("csvsql.duckdb")
local editor = require("csvsql.editor")
local sticky = require("csvsql.sticky")
local watcher_mod = require("csvsql.watcher")

local M = {}

---@type table<string, CsvSqlSession>
M.sessions_by_path = {}
---@type table<integer, CsvSqlSession>
M.sessions_by_buf = {}
---@type table<string, { query: string, truncate: boolean, wrap: boolean }>
M.saved_state = {}

local ns = vim.api.nvim_create_namespace("csvsql_highlights")
local zebra_ns = vim.api.nvim_create_namespace("csvsql_zebra")

---@param rgb integer
---@param delta integer
---@return string
local function shift_rgb(rgb, delta)
  local r = math.min(255, math.max(0, math.floor(rgb / 65536) % 256 + delta))
  local g = math.min(255, math.max(0, math.floor(rgb / 256) % 256 + delta))
  local b = math.min(255, math.max(0, (rgb % 256) + delta))
  return string.format("#%02x%02x%02x", r, g, b)
end

local function ensure_highlights()
  local existing_even = vim.api.nvim_get_hl(0, { name = "CsvSqlRowEven", link = false })
  if vim.tbl_isempty(existing_even) then
    local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
    if normal.bg then
      local r = math.floor(normal.bg / 65536) % 256
      local g = math.floor(normal.bg / 256) % 256
      local b = normal.bg % 256
      local lum = 0.299 * r + 0.587 * g + 0.114 * b
      local bg = shift_rgb(normal.bg, lum < 128 and 18 or -14)
      vim.api.nvim_set_hl(0, "CsvSqlRowEven", { default = true, bg = bg })
    elseif vim.o.background == "light" then
      vim.api.nvim_set_hl(0, "CsvSqlRowEven", { default = true, bg = "#ebedf0", ctermbg = 254 })
    else
      -- Visible subtle surface tint for transparent dark terminals
      vim.api.nvim_set_hl(0, "CsvSqlRowEven", { default = true, bg = "#1c2128", ctermbg = 235 })
    end
  end
  vim.api.nvim_set_hl(0, "CsvSqlRowOdd", { default = true, link = "Normal" })
end

---@param line string
---@param output_mode? string
---@return boolean
local function is_bottom_border(line, output_mode)
  local mode = output_mode or config.options.output_mode or "box"
  if mode == "box" then
    return vim.startswith(line, "└")
  elseif mode == "table" then
    return vim.startswith(line, "+")
  end
  return false
end

---@param session CsvSqlSession
---@param row_idx integer 0-based line index
local function add_even_mark(session, row_idx)
  local buf = session.view_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  session._zebra_marks[row_idx] = vim.api.nvim_buf_set_extmark(buf, zebra_ns, row_idx, 0, {
    line_hl_group = "CsvSqlRowEven",
    priority = 10,
  })
end

---@param session CsvSqlSession
local function sync_zebra_cursor(session)
  if not config.options.zebra_striping or not session._zebra_even_set then
    return
  end
  local buf = session.view_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local cur_win = vim.api.nvim_get_current_win()
  local cur_row = nil
  if vim.api.nvim_win_is_valid(cur_win) and vim.api.nvim_win_get_buf(cur_win) == buf then
    cur_row = vim.api.nvim_win_get_cursor(cur_win)[1] - 1
  end

  local prev_hidden = session._zebra_hidden_row
  if prev_hidden == cur_row then
    return
  end

  -- Restore stripe on previously hidden even row
  if prev_hidden ~= nil and session._zebra_even_set[prev_hidden] and not session._zebra_marks[prev_hidden] then
    add_even_mark(session, prev_hidden)
  end

  -- Temporarily clear stripe on current cursor row so CursorLine stays 100% visible
  if cur_row ~= nil and session._zebra_even_set[cur_row] then
    local id = session._zebra_marks[cur_row]
    if id then
      pcall(vim.api.nvim_buf_del_extmark, buf, zebra_ns, id)
      session._zebra_marks[cur_row] = nil
    end
    session._zebra_hidden_row = cur_row
  else
    session._zebra_hidden_row = nil
  end
end

---@class CsvSqlSession
---@field filepath string
---@field raw_buf integer|nil
---@field view_buf integer
---@field editor_buf integer|nil
---@field editor_win integer|nil
---@field query string
---@field truncate boolean
---@field wrap boolean
---@field last_lines string[]
---@field last_updated string|nil
---@field last_error string|nil
---@field watcher CsvSqlWatcher|nil
---@field _proc vim.SystemObj|nil
---@field _seq integer

---@param filepath string
---@return string
local function normalize_key(filepath)
  local abs = vim.fs.normalize(vim.fn.fnamemodify(filepath, ":p"))
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    return abs:lower()
  end
  return abs
end

---@param session CsvSqlSession
local function render_buffer(session)
  local buf = session.view_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  -- Save cursor & scroll state for every window displaying this buffer
  local saved_views = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) then
      saved_views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    end
  end

  local output = {}
  local banner_lines = {}
  local header_lines = 0
  local error_line_idx = nil

  if config.options.show_header then
    local watch_label = (session.watcher and session.watcher.active) and "LIVE" or "PAUSED"
    local trunc_label = session.truncate and ("TRUNC:" .. tostring(config.options.max_col_width or 48)) or "FULL"
    local wrap_label = session.wrap and "WRAP" or "NOWRAP"
    local updated = session.last_updated or "loading..."
    local short_file = vim.fs.basename(session.filepath)
    local single_line_sql = (session.query or ""):gsub("%s+", " ")
    if #single_line_sql > 90 then
      single_line_sql = single_line_sql:sub(1, 87) .. "..."
    end

    table.insert(
      banner_lines,
      string.format(
        "csvsql │ %s │ [%s] │ [%s] │ [%s] │ Updated: %s",
        short_file,
        watch_label,
        trunc_label,
        wrap_label,
        updated
      )
    )
    table.insert(banner_lines, string.format("SQL    │ %s", single_line_sql))
    header_lines = 2

    if session.last_error then
      local first_err = vim.split(session.last_error, "\n", { plain = true })[1] or session.last_error
      table.insert(banner_lines, string.format("ERROR  │ %s", first_err))
      error_line_idx = header_lines
      header_lines = header_lines + 1
    end

    table.insert(banner_lines, string.rep("─", 80))
    header_lines = header_lines + 1
  elseif session.last_error then
    local first_err = vim.split(session.last_error, "\n", { plain = true })[1] or session.last_error
    table.insert(banner_lines, "ERROR: " .. first_err)
    error_line_idx = 0
  end

  for _, line in ipairs(banner_lines) do
    table.insert(output, line)
  end

  session._banner_lines = banner_lines
  session._banner_error_line = error_line_idx
  session._table_header_lines = sticky.extract_table_header(session.last_lines, config.options.output_mode)

  for _, line in ipairs(session.last_lines) do
    table.insert(output, line)
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, output)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false

  ensure_highlights()
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if config.options.show_header then
    vim.api.nvim_buf_add_highlight(buf, ns, "Title", 0, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, ns, "Comment", 1, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, ns, "NonText", header_lines - 1, 0, -1)
  end
  if error_line_idx ~= nil then
    vim.api.nvim_buf_add_highlight(buf, ns, "ErrorMsg", error_line_idx, 0, -1)
  end

  -- Apply alternating row colors (zebra striping) to even table data rows
  vim.api.nvim_buf_clear_namespace(buf, zebra_ns, 0, -1)
  session._zebra_even_set = {}
  session._zebra_marks = {}
  session._zebra_hidden_row = nil

  if config.options.zebra_striping and #session._table_header_lines > 0 then
    local data_start = #banner_lines + #session._table_header_lines
    local data_end = #output - 1
    if data_end >= data_start and is_bottom_border(output[data_end + 1] or "", config.options.output_mode) then
      data_end = data_end - 1
    end
    for idx = data_start, data_end do
      local row_num = idx - data_start
      if row_num % 2 == 1 then
        session._zebra_even_set[idx] = true
        add_even_mark(session, idx)
      end
    end
  end

  -- Restore cursor & scroll position
  local total_lines = #output
  for win, view in pairs(saved_views) do
    if vim.api.nvim_win_is_valid(win) then
      if view.lnum > total_lines then
        view.lnum = math.max(1, total_lines)
      end
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(view)
      end)
    end
  end

  sync_zebra_cursor(session)
  sticky.update(session)
end

---@param session CsvSqlSession
local function setup_keymaps(session)
  local km = config.options.keymaps or {}
  local buf = session.view_buf
  local function map(lhs, fn, desc)
    if lhs and lhs ~= false and lhs ~= "" then
      vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, desc = desc })
    end
  end

  map(km.editor, function()
    editor.toggle(session)
  end, "csvsql: toggle SQL editor split")

  map(km.prompt, function()
    vim.ui.input({ prompt = "CsvSql> ", default = session.query }, function(input)
      if input and vim.trim(input) ~= "" then
        session:set_query(input)
      end
    end)
  end, "csvsql: run SQL query")

  map(km.reset, function()
    session:reset()
  end, "csvsql: reset SQL query")

  map(km.refresh, function()
    session:refresh()
  end, "csvsql: refresh table")

  map(km.toggle_raw, function()
    session:toggle_raw()
  end, "csvsql: toggle raw CSV view")

  map(km.toggle_watch, function()
    session:toggle_watch()
  end, "csvsql: toggle live file watcher")

  map(km.summarize, function()
    session:summarize()
  end, "csvsql: summarize columns")

  map(km.toggle_truncate, function()
    session:toggle_truncate()
  end, "csvsql: toggle column ellipsis / full mode")

  map(km.toggle_wrap, function()
    session:toggle_wrap()
  end, "csvsql: toggle viewbox line wrap")

  map(km.close, function()
    session:close()
  end, "csvsql: close viewer buffer")

  if config.options.safe_quit then
    vim.keymap.set("ca", "q", function()
      if vim.fn.getcmdtype() == ":" and vim.fn.getcmdline() == "q" then
        return "CsvSqlClose"
      end
      return "q"
    end, { buffer = buf, expr = true, desc = "csvsql: close viewer buffer on :q" })
  end
end

---@type table<integer, table<string, any>>
local saved_win_opts = {}

---@param win integer
---@param wrap boolean
local function configure_view_win(win, wrap)
  if not saved_win_opts[win] then
    saved_win_opts[win] = {
      wrap = vim.wo[win].wrap,
      number = vim.wo[win].number,
      relativenumber = vim.wo[win].relativenumber,
      signcolumn = vim.wo[win].signcolumn,
      foldcolumn = vim.wo[win].foldcolumn,
      statuscolumn = vim.wo[win].statuscolumn,
    }
  end
  vim.wo[win].wrap = wrap
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
end

---@param win integer
local function restore_view_win(win)
  local prev = saved_win_opts[win]
  if not prev then
    return
  end
  saved_win_opts[win] = nil
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  for k, v in pairs(prev) do
    pcall(function()
      vim.wo[win][k] = v
    end)
  end
end

---@param raw_buf integer|nil
---@param exclude_buf integer|nil
local function cleanup_raw_buf(raw_buf, exclude_buf)
  if
    raw_buf
    and raw_buf ~= exclude_buf
    and vim.api.nvim_buf_is_valid(raw_buf)
    and not vim.bo[raw_buf].modified
    and #vim.fn.win_findbuf(raw_buf) == 0
  then
    pcall(vim.api.nvim_buf_delete, raw_buf, { force = true })
  end
end

---@param filepath string
---@param raw_buf? integer
---@return CsvSqlSession
function M.open(filepath, raw_buf)
  local abs = vim.fs.normalize(vim.fn.fnamemodify(filepath, ":p"))
  local key = normalize_key(abs)

  local existing = M.sessions_by_path[key]
  if existing and vim.api.nvim_buf_is_valid(existing.view_buf) then
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, existing.view_buf)
    configure_view_win(win, existing.wrap)
    cleanup_raw_buf(raw_buf, existing.view_buf)
    existing:refresh()
    return existing
  end

  local buf = vim.api.nvim_create_buf(true, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "csvsql"

  local short_name = vim.fs.basename(abs)
  pcall(vim.api.nvim_buf_set_name, buf, string.format("csvsql://%s", short_name))

  local prev = M.saved_state[key]

  ---@type CsvSqlSession
  local session = {
    filepath = abs,
    raw_buf = nil,
    view_buf = buf,
    editor_buf = nil,
    editor_win = nil,
    query = (prev and prev.query) or duckdb.default_query(),
    truncate = prev and prev.truncate ~= nil and prev.truncate or config.options.truncate,
    wrap = prev and prev.wrap ~= nil and prev.wrap or config.options.wrap,
    last_lines = { "Loading..." },
    last_updated = nil,
    last_error = nil,
    watcher = nil,
    _proc = nil,
    _seq = 0,
  }

  function session:find_view_win()
    local wins = vim.fn.win_findbuf(self.view_buf)
    if #wins > 0 and vim.api.nvim_win_is_valid(wins[1]) then
      return wins[1]
    end
    return nil
  end

  function session:refresh()
    if not vim.api.nvim_buf_is_valid(self.view_buf) then
      return
    end
    -- Cancel stale in-flight process so fast writes don't pile up
    if self._proc then
      pcall(function()
        self._proc:kill(15)
      end)
      self._proc = nil
    end

    self._seq = self._seq + 1
    local current_seq = self._seq

    local run_opts = vim.tbl_extend("force", {}, config.options, {
      truncate = self.truncate,
    })

    self._proc = duckdb.run_query(self.filepath, self.query, function(res)
      if current_seq ~= self._seq then
        return
      end
      self._proc = nil
      if res.ok then
        self.last_lines = res.lines
        self.last_error = nil
        self.last_updated = os.date("%H:%M:%S")
      else
        -- Keep last valid table on screen and surface the error in the banner
        self.last_error = res.err or "unknown duckdb error"
      end
      render_buffer(self)
    end, run_opts)
  end

  function session:set_query(sql)
    local trimmed = vim.trim(sql or "")
    if trimmed == "" then
      trimmed = duckdb.default_query()
    end
    self.query = trimmed
    if self.editor_buf and vim.api.nvim_buf_is_valid(self.editor_buf) and not vim.bo[self.editor_buf].modified then
      vim.api.nvim_buf_set_lines(self.editor_buf, 0, -1, false, vim.split(self.query, "\n", { plain = true }))
      vim.bo[self.editor_buf].modified = false
    end
    self:refresh()
  end

  function session:reset()
    self:set_query(duckdb.default_query())
  end

  function session:summarize()
    local tbl = config.options.table_name or "data"
    self:set_query(string.format("SUMMARIZE %s", tbl))
  end

  function session:toggle_truncate()
    self.truncate = not self.truncate
    self:refresh()
  end

  function session:toggle_wrap()
    self.wrap = not self.wrap
    for _, win in ipairs(vim.fn.win_findbuf(self.view_buf)) do
      if vim.api.nvim_win_is_valid(win) then
        vim.wo[win].wrap = self.wrap
      end
    end
    render_buffer(self)
  end

  function session:toggle_watch()
    if not self.watcher then
      self.watcher = watcher_mod.new(self.filepath, config.options.debounce_ms, function()
        self:refresh()
      end)
    end
    if self.watcher.active then
      self.watcher:stop()
    else
      self.watcher:start()
    end
    render_buffer(self)
  end

  function session:toggle_raw()
    local view_buf = self.view_buf
    local win = self:find_view_win() or vim.api.nvim_get_current_win()

    -- Preserve active query & display preferences when switching to raw mode
    M.saved_state[key] = {
      query = self.query,
      truncate = self.truncate,
      wrap = self.wrap,
    }

    sticky.close(self)

    local target = vim.fn.bufadd(self.filepath)
    vim.b[target].csvsql_raw_mode = true
    vim.fn.bufload(target)
    vim.bo[target].buflisted = true

    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_buf(win, target)
      restore_view_win(win)
    end

    self:destroy()
    if vim.api.nvim_buf_is_valid(view_buf) then
      pcall(vim.api.nvim_buf_delete, view_buf, { force = true })
    end
  end

  function session:close()
    local view_buf = self.view_buf
    local raw_buf = self.raw_buf
    local wins = vim.api.nvim_buf_is_valid(view_buf) and vim.fn.win_findbuf(view_buf) or {}

    -- Find an existing listed buffer to switch to (including other csvsql buffers)
    local function is_fallback(b)
      return b ~= view_buf
        and b ~= raw_buf
        and vim.api.nvim_buf_is_valid(b)
        and vim.bo[b].buflisted
        and (vim.bo[b].buftype == "" or vim.bo[b].filetype == "csvsql")
    end

    local fallback = nil
    local alt = vim.fn.bufnr("#")
    if alt > 0 and is_fallback(alt) then
      fallback = alt
    end

    if not fallback then
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if is_fallback(b) then
          fallback = b
          break
        end
      end
    end

    if not fallback then
      fallback = vim.api.nvim_create_buf(true, false)
    end

    -- Switch all windows showing the viewer to the fallback buffer so Neovim never exits
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_buf(win, fallback)
      end
    end

    self:destroy()

    if vim.api.nvim_buf_is_valid(view_buf) then
      pcall(vim.api.nvim_buf_delete, view_buf, { force = true })
    end

    -- Clean up the hidden unmodified raw CSV buffer so it does not linger in the bufferline
    if
      raw_buf
      and raw_buf ~= fallback
      and vim.api.nvim_buf_is_valid(raw_buf)
      and not vim.bo[raw_buf].modified
      and #vim.fn.win_findbuf(raw_buf) == 0
    then
      pcall(vim.api.nvim_buf_delete, raw_buf, { force = true })
    end
  end

  function session:destroy()
    if self._destroyed then
      return
    end
    self._destroyed = true
    if self._proc then
      pcall(function()
        self._proc:kill(15)
      end)
      self._proc = nil
    end
    if self.watcher then
      self.watcher:stop()
      self.watcher = nil
    end
    editor.close(self)
    sticky.destroy(self)
    M.sessions_by_path[key] = nil
    M.sessions_by_buf[self.view_buf] = nil
  end

  M.sessions_by_path[key] = session
  M.sessions_by_buf[buf] = session

  setup_keymaps(session)

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    buffer = buf,
    once = true,
    callback = function()
      session:destroy()
    end,
  })

  vim.api.nvim_create_autocmd({ "WinScrolled", "CursorMoved", "WinResized", "BufWinEnter" }, {
    buffer = buf,
    callback = function(ev)
      if ev.event == "BufWinEnter" then
        configure_view_win(vim.api.nvim_get_current_win(), session.wrap)
      end
      sync_zebra_cursor(session)
      sticky.update(session)
    end,
  })

  vim.api.nvim_create_autocmd("BufWinLeave", {
    buffer = buf,
    callback = function()
      local leave_win = vim.api.nvim_get_current_win()
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(leave_win) and vim.api.nvim_win_get_buf(leave_win) ~= buf then
          restore_view_win(leave_win)
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufLeave", "WinClosed" }, {
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(buf) or not session:find_view_win() then
          sticky.close(session)
        end
      end)
    end,
  })

  if config.options.live_watch then
    session.watcher = watcher_mod.new(session.filepath, config.options.debounce_ms, function()
      session:refresh()
    end)
    session.watcher:start()
  end

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  configure_view_win(win, session.wrap)
  cleanup_raw_buf(raw_buf, buf)

  render_buffer(session)
  session:refresh()

  return session
end

---@param buf? integer
---@return CsvSqlSession|nil
function M.get_session(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if M.sessions_by_buf[buf] then
    return M.sessions_by_buf[buf]
  end
  -- Check if we are inside a session's SQL editor buffer
  for _, session in pairs(M.sessions_by_buf) do
    if session.editor_buf == buf then
      return session
    end
  end
  -- Check if we are inside a raw CSV buffer that has an active session
  local name = vim.api.nvim_buf_get_name(buf)
  if name and name ~= "" then
    return M.sessions_by_path[normalize_key(name)]
  end
  return nil
end

return M
