local Helpers = require("tests.helpers")
local Util = require("tests.sandbox_test_util")

local T = MiniTest.new_set()

-- Keep in sync with KNOWN_BACKENDS in lua/codecompanion/_extensions/run_bash/sandbox/init.lua.
local sandlock_driver = {
  name = "sandlock",
  sandbox_used = true,
  supports_named_sandbox = true,
  sandbox_opts = {
    backends = {
      sandlock = {
        profile = Helpers.sandbox_profile_path(),
      },
    },
  },
}

local bubblewrap_driver = {
  name = "bubblewrap",
  sandbox_used = true,
  supports_named_sandbox = false,
  sandbox_opts = {},
}

local none_driver = {
  name = "none",
  sandbox_used = false,
  supports_named_sandbox = false,
  sandbox_opts = { backend = false },
}

T["matrix"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      -- Parametrize args are not available here; per-driver skip is done in each case body.
    end,
  },
  parametrize = {
    { sandlock_driver },
    { bubblewrap_driver },
    { none_driver },
  },
})

local function skip_if_not_selected(driver)
  if not Helpers.should_test_backend(driver.name) then
    MiniTest.skip(string.format("Backend '%s' not selected for test", driver.name))
  end
end

local function expect_sandbox_meta(driver, result)
  MiniTest.expect.equality(driver.sandbox_used, result.sandbox_used, "sandbox_used mismatch")
  if driver.supports_named_sandbox then
    MiniTest.expect.equality("string", type(result.sandbox_name), "sandbox_name should be a string")
  else
    MiniTest.expect.equality(nil, result.sandbox_name, "sandbox_name should be nil")
  end
end

T["matrix"]["echo succeeds"] = function(driver)
  skip_if_not_selected(driver)
  local result = Util.run_and_wait(driver, "echo hello")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  Helpers.expect_contains("hello", result.content)
  MiniTest.expect.equality(0, result.exit_code)
end

T["matrix"]["exit code is propagated"] = function(driver)
  skip_if_not_selected(driver)
  local result = Util.run_and_wait(driver, "false")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  MiniTest.expect.equality(1, result.exit_code)
end

T["matrix"]["allowed read succeeds"] = function(driver)
  skip_if_not_selected(driver)
  local result = Util.run_and_wait(driver, "test -r /usr/bin/bash && echo ok")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  Helpers.expect_contains("ok", result.content)
  MiniTest.expect.equality(0, result.exit_code)
end

T["matrix"]["output interleaving"] = function(driver)
  skip_if_not_selected(driver)
  local result = Util.run_and_wait(driver, "echo out1; echo err1 >&2; echo out2")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  Helpers.expect_contains("out1", result.content)
  Helpers.expect_contains("err1", result.content)
  Helpers.expect_contains("out2", result.content)
end

T["matrix"]["multi-line command with pipe"] = function(driver)
  skip_if_not_selected(driver)
  local result = Util.run_and_wait(driver, "echo hello | sed 's/hello/world/'")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  Helpers.expect_contains("world", result.content)
end

T["matrix"]["stderr-only output"] = function(driver)
  skip_if_not_selected(driver)
  local result = Util.run_and_wait(driver, "echo err1 >&2")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  Helpers.expect_contains("err1", result.content)
end

T["matrix"]["empty output"] = function(driver)
  skip_if_not_selected(driver)
  local result = Util.run_and_wait(driver, "true")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  MiniTest.expect.equality(0, result.exit_code)
  -- Output may contain sandbox active note; just assert no error.
end

T["matrix"]["returns sandbox_used and sandbox_name"] = function(driver)
  skip_if_not_selected(driver)
  local result = Util.run_and_wait(driver, "echo x")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
end

T["matrix"]["kill terminates sleep"] = function(driver)
  skip_if_not_selected(driver)
  local result = Util.spawn(driver, "sleep 30")
  MiniTest.expect.equality(true, result.handle ~= nil, result.error or "")
  expect_sandbox_meta(driver, result)

  vim.wait(300, function()
    return false
  end, 50, true)

  Util.kill_and_wait(driver, result.pid, result.sandbox_name, nil, result)
  MiniTest.expect.equality(true, result.completed, "process should exit after kill")
end

T["matrix"]["kill callback fires"] = function(driver)
  skip_if_not_selected(driver)
  local result = Util.spawn(driver, "sleep 30")
  MiniTest.expect.equality(true, result.handle ~= nil, result.error or "")

  vim.wait(300, function()
    return false
  end, 50, true)

  local callback_fired = false
  Util.kill_and_wait(driver, result.pid, result.sandbox_name, function()
    callback_fired = true
  end, result)
  MiniTest.expect.equality(true, callback_fired, "kill callback should fire")
end

-- Isolation tests apply only to real sandbox backends, not the non-sandbox baseline.
T["isolation"] = MiniTest.new_set({
  parametrize = {
    { sandlock_driver },
    { bubblewrap_driver },
  },
})

T["isolation"]["allowed write succeeds"] = function(driver)
  skip_if_not_selected(driver)

  local file_path = "/tmp/cc-matrix-write-" .. math.random(10000, 99999) .. ".txt"
  local result = Util.run_and_wait(driver, "touch " .. file_path)
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  MiniTest.expect.equality(0, result.exit_code)
  pcall(os.remove, file_path)
end

T["isolation"]["fs_denied read fails"] = function(driver)
  skip_if_not_selected(driver)

  if driver.name == "sandlock" then
    local result = Util.run_and_wait(driver, "cat /etc/shadow 2>&1 || echo DENIED")
    MiniTest.expect.equality(true, result.completed, result.error or "")
    expect_sandbox_meta(driver, result)
    Helpers.expect_contains("DENIED", result.content)
    return
  end

  local deny_dir = Helpers.temp_dir()
  local marker = deny_dir .. "/marker.txt"
  local f = io.open(marker, "w")
  if f then
    f:write("secret")
    f:close()
  end
  local result = Util.run_and_wait(
    driver,
    "cat " .. marker .. " 2>&1 || echo DENIED",
    { fs_denied = { deny_dir } }
  )
  pcall(os.remove, marker)
  Helpers.cleanup_dir(deny_dir)
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  Helpers.expect_contains("DENIED", result.content)
end

T["isolation"]["fs_denied write fails"] = function(driver)
  skip_if_not_selected(driver)

  if driver.name == "sandlock" then
    local result =
      Util.run_and_wait(driver, "touch /tmp/cc-run-bash-test-deny/file 2>&1 || echo DENIED")
    MiniTest.expect.equality(true, result.completed, result.error or "")
    expect_sandbox_meta(driver, result)
    Helpers.expect_contains("DENIED", result.content)
    return
  end

  -- bubblewrap's --tmpfs turns a denied directory into an empty writable tmpfs,
  -- so "write fails" is not the right assertion. Verify the original content is
  -- masked instead.
  if driver.name == "bubblewrap" then
    local deny_dir = Helpers.temp_dir()
    local marker = deny_dir .. "/marker.txt"
    local f = io.open(marker, "w")
    if f then
      f:write("secret")
      f:close()
    end
    local result =
      Util.run_and_wait(driver, "ls " .. deny_dir .. " 2>&1", { fs_denied = { deny_dir } })
    pcall(os.remove, marker)
    Helpers.cleanup_dir(deny_dir)
    MiniTest.expect.equality(true, result.completed, result.error or "")
    expect_sandbox_meta(driver, result)
    MiniTest.expect.equality(
      nil,
      result.content:find("marker.txt", 1, true),
      "denied dir should be masked"
    )
    return
  end
end

T["isolation"]["fs_denied masks existing directory"] = function(driver)
  skip_if_not_selected(driver)

  if driver.name == "bubblewrap" then
    local deny_dir = Helpers.temp_dir()
    local marker = deny_dir .. "/marker.txt"
    local f = io.open(marker, "w")
    if f then
      f:write("x")
      f:close()
    end
    local result = Util.run_and_wait(
      driver,
      "ls " .. deny_dir .. " 2>&1 || echo MASKED",
      { fs_denied = { deny_dir } }
    )
    pcall(os.remove, marker)
    Helpers.cleanup_dir(deny_dir)
    MiniTest.expect.equality(true, result.completed, result.error or "")
    expect_sandbox_meta(driver, result)
    MiniTest.expect.equality(
      nil,
      result.content:find("marker.txt", 1, true),
      "denied dir should be masked"
    )
    return
  end

  -- sandlock: /etc is readable but /etc/shadow is denied.
  local result = Util.run_and_wait(driver, "cat /etc/shadow 2>&1 || echo MASKED")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  Helpers.expect_contains("MASKED", result.content)
end

return T
