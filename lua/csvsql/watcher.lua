local uv = vim.uv or vim.loop

local M = {}

---@class CsvSqlWatcher
---@field filepath string
---@field dir string
---@field filename string
---@field debounce_ms integer
---@field active boolean
---@field _fs_event any
---@field _timer any
---@field _on_change fun()

local IS_CASE_INSENSITIVE = (vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 or vim.fn.has("mac") == 1)

---@param a string
---@param b string
---@return boolean
local function filenames_match(a, b)
  if IS_CASE_INSENSITIVE then
    return a:lower() == b:lower()
  end
  return a == b
end

---@param filepath string
---@param debounce_ms integer
---@param on_change fun()
---@return CsvSqlWatcher
function M.new(filepath, debounce_ms, on_change)
  local abs = vim.fs.normalize(vim.fn.fnamemodify(filepath, ":p"))
  local watcher = {
    filepath = abs,
    dir = vim.fs.dirname(abs),
    filename = vim.fs.basename(abs),
    debounce_ms = debounce_ms or 200,
    active = false,
    _fs_event = nil,
    _timer = nil,
    _on_change = on_change,
  }

  ---@param self CsvSqlWatcher
  function watcher:start()
    if self.active then
      return true
    end
    if not self.dir or self.dir == "" then
      return false
    end

    local handle, err = uv.new_fs_event()
    if not handle then
      vim.notify("csvsql.nvim: failed to create file watcher: " .. tostring(err), vim.log.levels.WARN)
      return false
    end

    local timer = uv.new_timer()
    self._fs_event = handle
    self._timer = timer
    self.active = true

    -- Watch the parent directory so atomic save/rename writes are reliably detected on all OSes.
    local ok, start_err = handle:start(self.dir, {}, function(watch_err, fname)
      if watch_err then
        return
      end
      if fname and not filenames_match(fname, self.filename) then
        return
      end

      if self._timer and not self._timer:is_closing() then
        self._timer:stop()
        self._timer:start(self.debounce_ms, 0, function()
          vim.schedule(function()
            if self.active then
              self._on_change()
            end
          end)
        end)
      end
    end)

    if not ok then
      self:stop()
      vim.notify("csvsql.nvim: failed to watch directory: " .. tostring(start_err), vim.log.levels.WARN)
      return false
    end

    return true
  end

  ---@param self CsvSqlWatcher
  function watcher:stop()
    self.active = false
    if self._timer then
      if not self._timer:is_closing() then
        self._timer:stop()
        self._timer:close()
      end
      self._timer = nil
    end
    if self._fs_event then
      if not self._fs_event:is_closing() then
        self._fs_event:stop()
        self._fs_event:close()
      end
      self._fs_event = nil
    end
  end

  return watcher
end

return M
