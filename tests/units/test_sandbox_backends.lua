local Helpers = require("tests.helpers")
local Util = require("tests.sandbox_test_util")

local T = MiniTest.new_set()

-- Keep in sync with KNOWN_BACKENDS in lua/codecompanion/_extensions/run_bash/sandbox/init.lua.
local bubblewrap_backend = require("codecompanion._extensions.run_bash.sandbox.backends.bubblewrap")
local sandlock_backend = require("codecompanion._extensions.run_bash.sandbox.backends.sandlock")

local sandlock_driver = {
  name = "sandlock",
  sandbox_used = true,
  capabilities = sandlock_backend.capabilities(),
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
  capabilities = bubblewrap_backend.capabilities(),
  sandbox_opts = {},
}

local none_driver = {
  name = "none",
  sandbox_used = false,
  capabilities = { kill_by_name = false, fs_deny_files = false, fs_deny_dirs = false },
  sandbox_opts = { backend = false },
}

-- Custom driver injection from environment variable
local custom_driver = nil
local custom_module_path = os.getenv("TEST_CC_RUN_BASH_CUSTOM_BACKEND")
if custom_module_path and custom_module_path ~= "" then
  local ok, mod = pcall(require, custom_module_path)
  if not ok then
    error("Failed to load custom backend module '" .. custom_module_path .. "': " .. tostring(mod))
  end
  -- Validate capabilities
  local caps = mod.capabilities()
  assert(type(caps) == "table", "custom backend capabilities() must return a table")
  assert(
    type(caps.kill_by_name) == "boolean",
    "custom backend capabilities().kill_by_name must be a boolean"
  )
  assert(
    caps.fs_deny_files == true or caps.fs_deny_files == false,
    "custom backend capabilities().fs_deny_files must be a boolean"
  )
  assert(
    caps.fs_deny_dirs == false or caps.fs_deny_dirs == "block" or caps.fs_deny_dirs == "mask",
    "custom backend capabilities().fs_deny_dirs must be false, 'block', or 'mask'"
  )
  custom_driver = {
    name = "custom",
    is_custom = true,
    sandbox_used = true,
    capabilities = caps,
    sandbox_opts = {
      backends = {
        custom = {
          module = custom_module_path,
        },
      },
    },
  }
end

T["matrix"] = MiniTest.new_set({
  hooks = {
    pre_case = function()
      -- Parametrize args are not available here; per-driver skip is done in each case body.
    end,
  },
  parametrize = (function()
    local list = {
      { sandlock_driver },
      { bubblewrap_driver },
      { none_driver },
    }
    if custom_driver then
      table.insert(list, { custom_driver })
    end
    return list
  end)(),
})

local function skip_guard(driver)
  if driver.is_custom then
    if not custom_driver then
      MiniTest.skip("Custom backend not configured (TEST_CC_RUN_BASH_CUSTOM_BACKEND not set)")
    end
  else
    if not Helpers.should_test_backend(driver.name) then
      MiniTest.skip(string.format("Backend '%s' not selected for test", driver.name))
    end
  end
end

local function expect_sandbox_meta(driver, result)
  MiniTest.expect.equality(driver.sandbox_used, result.sandbox_used, "sandbox_used mismatch")
  if driver.capabilities.kill_by_name then
    MiniTest.expect.equality("string", type(result.sandbox_name), "sandbox_name should be a string")
  else
    MiniTest.expect.equality(nil, result.sandbox_name, "sandbox_name should be nil")
  end
end

T["matrix"]["echo succeeds"] = function(driver)
  skip_guard(driver)
  local result = Util.run_and_wait(driver, "echo hello")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  Helpers.expect_contains("hello", result.content)
  MiniTest.expect.equality(0, result.exit_code)
end

T["matrix"]["exit code is propagated"] = function(driver)
  skip_guard(driver)
  local result = Util.run_and_wait(driver, "false")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  MiniTest.expect.equality(1, result.exit_code)
end

T["matrix"]["allowed read succeeds"] = function(driver)
  skip_guard(driver)
  local result = Util.run_and_wait(driver, "test -r /usr/bin/bash && echo ok")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  Helpers.expect_contains("ok", result.content)
  MiniTest.expect.equality(0, result.exit_code)
end

T["matrix"]["writable device rule works"] = function(driver)
  -- Intent: a device path in fs_writable must be openable for writing inside
  -- the sandbox on every backend — device usability is part of the common
  -- backend contract, not bubblewrap-specific.
  -- build_sandbox_opts merges rule overrides with vim.tbl_deep_extend("force"),
  -- which merges lists index by index instead of replacing them: fs_writable
  -- { "/dev/null" } over common_rules { ".", "/tmp" } yields
  -- { "/dev/null", "/tmp" }, dropping the cwd grant. This command only writes
  -- to /dev/null, so the missing cwd grant does not affect it.
  skip_guard(driver)
  local result =
    Util.run_and_wait(driver, "echo x > /dev/null && echo DEVOK", { fs_writable = { "/dev/null" } })
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  Helpers.expect_contains("DEVOK", result.content)
  MiniTest.expect.equality(0, result.exit_code)
end

T["matrix"]["readable device rule works"] = function(driver)
  -- Intent: a device path in fs_readable must be openable for reading inside
  -- the sandbox on every backend — same common-contract rationale as the
  -- writable case above.
  -- build_sandbox_opts merges rule overrides index by index (see the writable
  -- case above), so fs_readable is built from common_rules and /dev/null is
  -- appended at the end: indices 1-5 match the defaults and are preserved,
  -- keeping the userland paths that bash and head need. Deriving from
  -- common_rules keeps this list correct as those defaults evolve.
  skip_guard(driver)
  local readable = vim.list_extend(vim.deepcopy(Util.common_rules.fs_readable), { "/dev/null" })
  local result =
    Util.run_and_wait(driver, "head -c0 /dev/null && echo DEVOK", { fs_readable = readable })
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  Helpers.expect_contains("DEVOK", result.content)
  MiniTest.expect.equality(0, result.exit_code)
end

T["matrix"]["output interleaving"] = function(driver)
  skip_guard(driver)
  local result = Util.run_and_wait(driver, "echo out1; echo err1 >&2; echo out2")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  Helpers.expect_contains("out1", result.content)
  Helpers.expect_contains("err1", result.content)
  Helpers.expect_contains("out2", result.content)
end

T["matrix"]["multi-line command with pipe"] = function(driver)
  skip_guard(driver)
  local result = Util.run_and_wait(driver, "echo hello | sed 's/hello/world/'")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  Helpers.expect_contains("world", result.content)
end

T["matrix"]["stderr-only output"] = function(driver)
  skip_guard(driver)
  local result = Util.run_and_wait(driver, "echo err1 >&2")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  Helpers.expect_contains("err1", result.content)
end

T["matrix"]["empty output"] = function(driver)
  skip_guard(driver)
  local result = Util.run_and_wait(driver, "true")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  MiniTest.expect.equality(0, result.exit_code)
  -- Output may contain sandbox active note; just assert no error.
end

T["matrix"]["returns sandbox_used and sandbox_name"] = function(driver)
  skip_guard(driver)
  local result = Util.run_and_wait(driver, "echo x")
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
end

T["matrix"]["kill terminates sleep"] = function(driver)
  skip_guard(driver)
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
  skip_guard(driver)
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
  parametrize = (function()
    local list = {
      { sandlock_driver },
      { bubblewrap_driver },
    }
    if custom_driver then
      table.insert(list, { custom_driver })
    end
    return list
  end)(),
})

T["isolation"]["allowed write succeeds"] = function(driver)
  skip_guard(driver)

  local file_path = "/tmp/cc-matrix-write-" .. math.random(10000, 99999) .. ".txt"
  local result = Util.run_and_wait(driver, "touch " .. file_path)
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  MiniTest.expect.equality(0, result.exit_code)
  pcall(os.remove, file_path)
end

T["isolation"]["cwd write via dot rule succeeds"] = function(driver)
  skip_guard(driver)

  -- Default-config rules grant cwd write via "."; the resolver must anchor
  -- it to the process cwd or the sandboxed touch cannot create the file here.
  local file_path = "./cc-matrix-dot-" .. math.random(10000, 99999) .. ".tmp"
  local result = Util.run_and_wait(driver, "touch " .. file_path)
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  MiniTest.expect.equality(0, result.exit_code)
  pcall(os.remove, file_path)
end

T["isolation"]["fs_denied read fails"] = function(driver)
  skip_guard(driver)

  local caps = driver.capabilities
  -- Skip if backend cannot deny files or directories at all
  if not caps.fs_deny_files and caps.fs_deny_dirs == false then
    MiniTest.skip("Backend cannot deny files or directories")
  end
  -- Backends with fs_deny_dirs == "mask" skip this case; their directory-masking behavior
  -- is covered by "fs_denied masks existing directory".
  if caps.fs_deny_dirs == "mask" and not caps.fs_deny_files then
    MiniTest.skip("Backend only masks directories, covered by other test")
  end

  -- Test file denial if supported
  if caps.fs_deny_files then
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
      { fs_denied = { marker } }
    )
    pcall(os.remove, marker)
    Helpers.cleanup_dir(deny_dir)
    MiniTest.expect.equality(true, result.completed, result.error or "")
    expect_sandbox_meta(driver, result)
    Helpers.expect_contains("DENIED", result.content)
    return
  end

  -- Test directory denial if supported (block mode)
  if caps.fs_deny_dirs == "block" then
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
    return
  end

  MiniTest.skip("No applicable denial capability for this test")
end

T["isolation"]["fs_denied write fails"] = function(driver)
  skip_guard(driver)

  -- Skip unless backend supports directory blocking
  if driver.capabilities.fs_deny_dirs ~= "block" then
    MiniTest.skip("Backend does not support directory blocking (fs_deny_dirs != 'block')")
  end

  local deny_dir = Helpers.temp_dir()
  local file_path = deny_dir .. "/test.txt"
  local result = Util.run_and_wait(
    driver,
    "touch " .. file_path .. " 2>&1 || echo DENIED",
    { fs_denied = { deny_dir } }
  )
  Helpers.cleanup_dir(deny_dir)
  MiniTest.expect.equality(true, result.completed, result.error or "")
  expect_sandbox_meta(driver, result)
  Helpers.expect_contains("DENIED", result.content)
end

T["isolation"]["fs_denied masks existing directory"] = function(driver)
  skip_guard(driver)

  -- Skip unless backend supports directory masking
  if driver.capabilities.fs_deny_dirs ~= "mask" then
    MiniTest.skip("Backend does not support directory masking (fs_deny_dirs != 'mask')")
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
end

-- Capability enum tests for built-in backends
T["capabilities"] = MiniTest.new_set()

T["capabilities"]["sandlock returns correct enum capabilities"] = function()
  local backend = require("codecompanion._extensions.run_bash.sandbox.backends.sandlock")
  local caps = backend.capabilities()
  MiniTest.expect.equality(true, caps.kill_by_name)
  MiniTest.expect.equality(true, caps.fs_deny_files)
  MiniTest.expect.equality("block", caps.fs_deny_dirs)
end

T["capabilities"]["bubblewrap returns correct enum capabilities"] = function()
  local backend = require("codecompanion._extensions.run_bash.sandbox.backends.bubblewrap")
  local caps = backend.capabilities()
  MiniTest.expect.equality(false, caps.kill_by_name)
  MiniTest.expect.equality(false, caps.fs_deny_files)
  MiniTest.expect.equality("mask", caps.fs_deny_dirs)
end

return T
