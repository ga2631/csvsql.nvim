local config = require("csvsql.config")

local M = {}

---@param session table CsvSqlSession
function M.toggle(session)
  -- Close if already open
  if session.editor_win and vim.api.nvim_win_is_valid(session.editor_win) then
    vim.api.nvim_win_close(session.editor_win, true)
    session.editor_win = nil
    return
  end

  local view_win = session:find_view_win()
  if view_win then
    vim.api.nvim_set_current_win(view_win)
  end

  local height = config.options.editor_height or 8
  vim.cmd(string.format("botright %dsplit", height))
  local win = vim.api.nvim_get_current_win()

  local buf = session.editor_buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "sql"

    local short_name = vim.fs.basename(session.filepath)
    pcall(vim.api.nvim_buf_set_name, buf, string.format("csvsql://query/%s", short_name))

    local initial_lines = vim.split(session.query, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines)
    vim.bo[buf].modified = false

    local function run_from_editor()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local sql = vim.trim(table.concat(lines, "\n"))
      vim.bo[buf].modified = false
      session:set_query(sql)
    end

    -- Allow :w to execute the SQL query cleanly
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = buf,
      callback = run_from_editor,
    })

    vim.keymap.set("n", "<CR>", run_from_editor, {
      buffer = buf,
      silent = true,
      desc = "csvsql: execute SQL query",
    })
    vim.keymap.set({ "n", "i" }, "<C-s>", function()
      if vim.fn.mode() == "i" then
        vim.cmd("stopinsert")
      end
      run_from_editor()
    end, {
      buffer = buf,
      silent = true,
      desc = "csvsql: execute SQL query",
    })
    vim.keymap.set("n", "q", function()
      if session.editor_win and vim.api.nvim_win_is_valid(session.editor_win) then
        vim.api.nvim_win_close(session.editor_win, true)
        session.editor_win = nil
      end
    end, {
      buffer = buf,
      silent = true,
      desc = "csvsql: close SQL editor",
    })

    session.editor_buf = buf
  else
    -- Sync current active query into existing editor buffer if unmodified
    if not vim.bo[buf].modified then
      local lines = vim.split(session.query, "\n", { plain = true })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modified = false
    end
  end

  vim.api.nvim_win_set_buf(win, buf)
  vim.wo[win].number = true
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = true
  vim.wo[win].winfixheight = true
  session.editor_win = win
end

---@param session table CsvSqlSession
function M.close(session)
  if session.editor_win and vim.api.nvim_win_is_valid(session.editor_win) then
    pcall(vim.api.nvim_win_close, session.editor_win, true)
  end
  session.editor_win = nil
  if session.editor_buf and vim.api.nvim_buf_is_valid(session.editor_buf) then
    pcall(vim.api.nvim_buf_delete, session.editor_buf, { force = true })
  end
  session.editor_buf = nil
end

return M
