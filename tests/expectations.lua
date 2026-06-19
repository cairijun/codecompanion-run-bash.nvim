-- Custom expectations for mini.test
local H = {}

---Custom expectation: string contains pattern (literal match)
---@param str string
---@param pattern string
---@return boolean
H.expect_contains = MiniTest.new_expectation("string contains", function(pattern, str)
  if type(str) ~= "string" then
    return false
  end
  return str:find(pattern, 1, true) ~= nil
end, function(pattern, str)
  return string.format(
    "\nExpected string to contain:\n%s\n\nActual:\n%s",
    vim.inspect(pattern),
    type(str) == "string" and str or vim.inspect(str)
  )
end)

return H
