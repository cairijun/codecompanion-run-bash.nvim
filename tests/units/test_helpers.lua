local Helpers = require("tests.helpers")

local T = MiniTest.new_set()

T["with_mocks restores original after success"] = function()
  local orig_spawn = vim.uv.spawn
  local mock_called = false

  local result = Helpers.with_mocks({
    ["vim.uv.spawn"] = function(...)
      mock_called = true
      return "mock"
    end,
  }, function()
    vim.uv.spawn()
    return 42
  end)

  MiniTest.expect.equality(42, result)
  MiniTest.expect.equality(true, mock_called)
  MiniTest.expect.equality(orig_spawn, vim.uv.spawn)
end

T["with_mocks restores original after body error"] = function()
  local orig_spawn = vim.uv.spawn

  local ok = pcall(function()
    Helpers.with_mocks({
      ["vim.uv.spawn"] = function() end,
    }, function()
      error("boom")
    end)
  end)

  MiniTest.expect.equality(false, ok)
  MiniTest.expect.equality(orig_spawn, vim.uv.spawn)
end

T["with_mocks supports nested module-key form"] = function()
  local orig_spawn = vim.uv.spawn
  local orig_schedule = vim.schedule
  local called = {}

  Helpers.with_mocks({
    vim = {
      uv = {
        spawn = function()
          called.spawn = true
        end,
      },
      schedule = function()
        called.schedule = true
      end,
    },
  }, function()
    vim.uv.spawn()
    vim.schedule()
  end)

  MiniTest.expect.equality(true, called.spawn)
  MiniTest.expect.equality(true, called.schedule)
  MiniTest.expect.equality(orig_spawn, vim.uv.spawn)
  MiniTest.expect.equality(orig_schedule, vim.schedule)
end

T["with_mocks errors on nested same-key mocks"] = function()
  local ok = pcall(function()
    Helpers.with_mocks({
      ["vim.uv.spawn"] = function() end,
    }, function()
      Helpers.with_mocks({
        ["vim.uv.spawn"] = function() end,
      }, function() end)
    end)
  end)

  MiniTest.expect.equality(false, ok)
end

return T
