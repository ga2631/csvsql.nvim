local config = require("csvsql.config")

local M = {}

local ns = vim.api.nvim_create_namespace("csvsql_sticky_highlights")

---@param lines string[]
---@param output_mode? string
---@return string[]
function M.extract_table_header(lines, output_mode)
  if type(lines) ~= "table" or #lines == 0 then
    return {}
  end
  local mode = output_mode or config.options.output_mode or "box"

  if mode == "box" then
    if #lines >= 3 and vim.startswith(lines[1], "┌") and vim.startswith(lines[3], "├") then
      return { lines[1], lines[2], lines[3] }
    end
  elseif mode == "markdown" then
    if #lines >= 2 and vim.startswith(lines[1], "|") and lines[2]:match("^|%s*%-") then
      return { lines[1], lines[2] }
    end
  elseif mode == "table" then
    if #lines >= 3 and vim.startswith(lines[1], "+") and vim.startswith(lines[3], "+") then
      return { lines[1], lines[2], lines[3] }
    end
  elseif mode == "column" then
    if #lines >= 2 and lines[2]:match("^%-+") then
      return { lines[1], lines[2] }
    end
  end

  return {}
end

---@param win integer|nil
local function close_win(win)
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

---@param buf integer|nil
local function delete_buf(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

---@param buf integer|nil
---@return integer
local function ensure_buf(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].swapfile = false
  vim.bo[b].modifiable = false
  return b
end

---@param existing_win integer|nil
---@param buf integer
---@param parent_win integer
---@param row integer
---@param width integer
---@param height integer
---@return integer|nil
local function open_or_update_float(existing_win, buf, parent_win, row, width, height)
  local win_opts = {
    relative = "win",
    win = parent_win,
    row = row,
    col = 0,
    width = math.max(1, width),
    height = math.max(1, height),
    focusable = false,
    style = "minimal",
    border = "none",
    zindex = 20,
    noautocmd = true,
  }

  if existing_win and vim.api.nvim_win_is_valid(existing_win) then
    local ok = pcall(vim.api.nvim_win_set_config, existing_win, win_opts)
    if ok then
      if vim.api.nvim_win_get_buf(existing_win) ~= buf then
        pcall(vim.api.nvim_win_set_buf, existing_win, buf)
      end
      return existing_win
    end
    close_win(existing_win)
  end

  local ok, win = pcall(vim.api.nvim_open_win, buf, false, win_opts)
  if not ok then
    return nil
  end
  vim.wo[win].wrap = false
  vim.wo[win].winhl = "Normal:Normal"
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
  return win
end

---@param session table
function M.close(session)
  close_win(session._sticky_banner_win)
  close_win(session._sticky_table_win)
  session._sticky_banner_win = nil
  session._sticky_table_win = nil
end

---@param session table
function M.destroy(session)
  M.close(session)
  delete_buf(session._sticky_banner_buf)
  delete_buf(session._sticky_table_buf)
  session._sticky_banner_buf = nil
  session._sticky_table_buf = nil
end

---@param session table
function M.update(session)
  if not config.options.sticky_header or session.wrap then
    M.close(session)
    return
  end

  local view_buf = session.view_buf
  if not view_buf or not vim.api.nvim_buf_is_valid(view_buf) then
    M.close(session)
    return
  end

  local cur_win = vim.api.nvim_get_current_win()
  local parent_win = nil
  if vim.api.nvim_win_is_valid(cur_win) and vim.api.nvim_win_get_buf(cur_win) == view_buf then
    parent_win = cur_win
  else
    parent_win = session:find_view_win()
  end

  if not parent_win or not vim.api.nvim_win_is_valid(parent_win) then
    M.close(session)
    return
  end

  local win_view = vim.api.nvim_win_call(parent_win, vim.fn.winsaveview)
  if not win_view then
    M.close(session)
    return
  end

  local scrolled_down = (win_view.topline or 1) > 1
  local scrolled_right = (win_view.leftcol or 0) > 0

  if not scrolled_down and not scrolled_right then
    M.close(session)
    return
  end

  local banner_lines = session._banner_lines or {}
  local table_lines = session._table_header_lines or {}
  local show_banner = #banner_lines > 0 and (scrolled_down or scrolled_right)
  local show_table_hdr = #table_lines > 0 and scrolled_down
  local total_h = (show_banner and #banner_lines or 0) + (show_table_hdr and #table_lines or 0)
  local win_h = vim.api.nvim_win_get_height(parent_win)
  local win_w = vim.api.nvim_win_get_width(parent_win)

  if total_h == 0 or win_h <= total_h + 2 then
    M.close(session)
    return
  end

  -- 1. Pinned status/SQL banner (always leftcol = 0 on vertical OR horizontal scroll)
  if show_banner then
    local bbuf = ensure_buf(session._sticky_banner_buf)
    session._sticky_banner_buf = bbuf

    vim.bo[bbuf].modifiable = true
    vim.api.nvim_buf_set_lines(bbuf, 0, -1, false, banner_lines)
    vim.bo[bbuf].modifiable = false

    vim.api.nvim_buf_clear_namespace(bbuf, ns, 0, -1)
    if config.options.show_header then
      vim.api.nvim_buf_add_highlight(bbuf, ns, "Title", 0, 0, -1)
      if #banner_lines >= 2 then
        vim.api.nvim_buf_add_highlight(bbuf, ns, "Comment", 1, 0, -1)
      end
      vim.api.nvim_buf_add_highlight(bbuf, ns, "NonText", #banner_lines - 1, 0, -1)
    end
    if session._banner_error_line ~= nil and session._banner_error_line < #banner_lines then
      vim.api.nvim_buf_add_highlight(bbuf, ns, "ErrorMsg", session._banner_error_line, 0, -1)
    end

    session._sticky_banner_win =
      open_or_update_float(session._sticky_banner_win, bbuf, parent_win, 0, win_w, #banner_lines)
    if session._sticky_banner_win and vim.api.nvim_win_is_valid(session._sticky_banner_win) then
      vim.api.nvim_win_call(session._sticky_banner_win, function()
        vim.fn.winrestview({ topline = 1, leftcol = 0 })
      end)
    end
  else
    close_win(session._sticky_banner_win)
    session._sticky_banner_win = nil
  end

  -- 2. Pinned table column header (only when scrolled down; synced horizontally with parent_win.leftcol)
  if show_table_hdr then
    local tbuf = ensure_buf(session._sticky_table_buf)
    session._sticky_table_buf = tbuf

    vim.bo[tbuf].modifiable = true
    vim.api.nvim_buf_set_lines(tbuf, 0, -1, false, table_lines)
    vim.bo[tbuf].modifiable = false

    local table_row = show_banner and #banner_lines or 0
    session._sticky_table_win =
      open_or_update_float(session._sticky_table_win, tbuf, parent_win, table_row, win_w, #table_lines)
    if session._sticky_table_win and vim.api.nvim_win_is_valid(session._sticky_table_win) then
      vim.api.nvim_win_call(session._sticky_table_win, function()
        vim.fn.winrestview({ topline = 1, leftcol = win_view.leftcol or 0 })
      end)
    end
  else
    close_win(session._sticky_table_win)
    session._sticky_table_win = nil
  end
end

return M
