local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)
vim.cmd("runtime plugin/csvsql.lua")

_G.CsvSqlTest = {
  passed = 0,
  failed = 0,
}

function _G.CsvSqlTest.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    _G.CsvSqlTest.passed = _G.CsvSqlTest.passed + 1
    io.write("  PASS  " .. name .. "\n")
  else
    _G.CsvSqlTest.failed = _G.CsvSqlTest.failed + 1
    io.write("  FAIL  " .. name .. "\n    " .. tostring(err) .. "\n")
  end
end

function _G.CsvSqlTest.assert_eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(
      string.format(
        "%s\nExpected: %s\nActual:   %s",
        msg or "Assertion failed",
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

function _G.CsvSqlTest.assert_true(cond, msg)
  if not cond then
    error(msg or "Expected truthy value", 2)
  end
end

function _G.CsvSqlTest.finish()
  io.write(string.format("\nResults: %d passed, %d failed\n", _G.CsvSqlTest.passed, _G.CsvSqlTest.failed))
  if _G.CsvSqlTest.failed > 0 then
    vim.cmd("cquit 1")
  else
    vim.cmd("qall!")
  end
end
