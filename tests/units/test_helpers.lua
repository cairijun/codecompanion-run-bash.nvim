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

T["should_test_backend parses env var"] = function()
  local var_name = "TEST_CC_RUN_BASH_SANDBOX_BACKENDS"
  local orig = os.getenv(var_name)

  local function set_env(value)
    if value == nil then
      vim.fn.setenv(var_name, vim.NIL)
    else
      vim.fn.setenv(var_name, value)
    end
  end

  local cases = {
    { nil, "sandlock", true },
    { nil, "bubblewrap", true },
    { "", "sandlock", false },
    { "sandlock", "sandlock", true },
    { "sandlock", "bubblewrap", false },
    { "sandlock", "Sandlock", false },
    { "sandlock,bubblewrap", "bubblewrap", true },
    { " sandlock , bubblewrap ", "sandlock", true },
    { "sandlock", "none", false },
    { "sandlock,", "sandlock", true },
  }

  for _, c in ipairs(cases) do
    set_env(c[1])
    local got = Helpers.should_test_backend(c[2])
    MiniTest.expect.equality(c[3], got, string.format("env=%s name=%s", vim.inspect(c[1]), c[2]))
  end

  set_env(orig)
end

return T
