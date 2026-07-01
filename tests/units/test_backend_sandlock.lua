--[[
Test: backends/sandlock.lua — Sandlock Backend

Intent: Verify sandlock backend builds correct CLI args, checks executable
and profile availability, validates config, reports capabilities, and
correctly dispatches run/kill via spawn spies.
]]

local Helpers = require("tests.helpers")
local backend = require("codecompanion._extensions.run_bash.sandbox.backends.sandlock")

local T = MiniTest.new_set()

-- Rules sufficient to run /bin/bash and its shared libraries inside sandlock.
local common_rules = {
  writable = { vim.fn.getcwd(), "/tmp" },
  readable = { vim.fn.getcwd(), "/usr", "/bin", "/lib", "/lib64" },
  denied = {},
}

local function truthy_fs()
  return {}
end

local function no_op() end

-- ── _build_args tests ────────────────────────────────────────────

T["build_args: empty rules produce minimal arg table"] = function()
  local args = backend._build_args(
    { profile = "/tmp/fake.toml" },
    "echo hi",
    "sb",
    { readable = {}, writable = {}, denied = {} }
  )
  MiniTest.expect.equality({
    "run",
    "--profile-file",
    "/tmp/fake.toml",
    "--name",
    "sb",
    "--port-remap",
    "--",
    "bash",
    "-c",
    "echo hi",
  }, args)
end

T["build_args: writable/readable/denied expanded in order"] = function()
  local args = backend._build_args(
    { profile = "/tmp/fake.toml" },
    "ls",
    "test-sb",
    { readable = { "/usr" }, writable = { "/var" }, denied = { "/nonexistent-deny" } }
  )
  MiniTest.expect.equality({
    "run",
    "--profile-file",
    "/tmp/fake.toml",
    "--name",
    "test-sb",
    "--port-remap",
    "-w",
    "/var",
    "-r",
    "/usr",
    "--fs-deny",
    "/nonexistent-deny",
    "--",
    "bash",
    "-c",
    "ls",
  }, args)
end

T["build_args: extra_args inserted before --"] = function()
  local args = backend._build_args(
    { profile = "/tmp/fake.toml", extra_args = { "--allow-degraded" } },
    "echo hi",
    "test-sb",
    { readable = {}, writable = {}, denied = {} }
  )
  local dash_idx, extra_idx
  for i, v in ipairs(args) do
    if v == "--" and not dash_idx then
      dash_idx = i
    end
    if v == "--allow-degraded" then
      extra_idx = i
    end
  end
  MiniTest.expect.equality(true, dash_idx ~= nil)
  MiniTest.expect.equality(true, extra_idx ~= nil)
  MiniTest.expect.equality(true, extra_idx < dash_idx)
end

-- ── is_available tests ───────────────────────────────────────────

T["is_available: true when sandlock and profile present"] = function()
  if not Helpers.should_test_backend("sandlock") then
    MiniTest.skip("sandlock not selected")
  end
  MiniTest.expect.equality(true, backend.is_available({ profile = Helpers.sandbox_profile_path() }))
end

T["is_available: false when no profile"] = function()
  MiniTest.expect.equality(false, backend.is_available({ profile = nil }))
end

-- ── validate_opts tests ──────────────────────────────────────────

T["validate_opts: valid config returns nil"] = function()
  MiniTest.expect.equality(
    nil,
    backend.validate_opts({ profile = "/tmp/fake.toml", extra_args = {} })
  )
end

T["validate_opts: invalid extra_args returns error"] = function()
  local err = backend.validate_opts({ profile = "/tmp/fake.toml", extra_args = "bad" })
  MiniTest.expect.equality(true, type(err) == "string" and err ~= "")
end

-- ── capabilities tests ───────────────────────────────────────────

T["capabilities: returns expected flags"] = function()
  MiniTest.expect.equality({
    named_sandbox = true,
  }, backend.capabilities())
end

-- ── run spy tests ────────────────────────────────────────────────

T["run: sandbox mode spawns sandlock"] = function()
  local captured = {}
  local function spawn_stub(exe, opts, on_exit)
    captured.exe = exe
    captured.args = opts.args
    return {}, 12345
  end

  local handle, pid, sandbox_used, sandbox_name = backend.run(
    { profile = "/tmp/fake-profile.toml" },
    {
      cmd = "echo hi",
      fd = 3,
      on_exit = no_op,
      sandbox_name = "cc-test-spy",
      resolved_rules = { readable = {}, writable = {}, denied = {} },
      deps = { spawn = spawn_stub, unref = no_op },
    }
  )

  MiniTest.expect.equality("sandlock", captured.exe)
  MiniTest.expect.equality(true, handle ~= nil, "should return a handle")
  MiniTest.expect.equality(12345, pid)
  MiniTest.expect.equality(true, sandbox_used)
  MiniTest.expect.equality("cc-test-spy", sandbox_name)
end

-- ── kill spy tests ────────────────────────────────────────────────

T["kill: spawns sandlock kill with sandbox_name"] = function()
  local captured = {}
  local function spawn_stub(exe, opts, on_exit)
    captured.exe = exe
    captured.args = opts.args
    if on_exit then
      on_exit()
    end
    return {}, 99999
  end

  backend.kill({}, "sb", 12345, no_op, {
    spawn = spawn_stub,
    close = no_op,
    unref = no_op,
  })

  MiniTest.expect.equality("sandlock", captured.exe)
  MiniTest.expect.equality("kill", captured.args[1])
  MiniTest.expect.equality("sb", captured.args[2])
end

T["run: real sandlock executes echo"] = function()
  if not Helpers.should_test_backend("sandlock") then
    MiniTest.skip("sandlock not selected")
  end

  local uv = vim.uv
  local file_path = "/tmp/cc-sb-real-run-" .. math.random(10000, 99999) .. ".out"
  local fd = uv.fs_open(file_path, "w", 420)
  MiniTest.expect.equality(true, fd ~= nil)

  local exit_code = nil
  local done = false
  local sandbox_name = "cc-sb-real-run-" .. math.random(10000, 99999)
  local handle, pid, sandbox_used, returned_name = backend.run(
    { profile = Helpers.sandbox_profile_path() },
    {
      cmd = "echo hello",
      fd = fd,
      on_exit = function(code)
        exit_code = code
        done = true
      end,
      resolved_rules = common_rules,
      sandbox_name = sandbox_name,
    }
  )

  if handle then
    uv.unref(handle)
  end

  local ok = vim.wait(5000, function()
    return done
  end, 50, true)
  pcall(uv.fs_close, fd)
  local content = (uv.fs_stat(file_path) and io.open(file_path, "r"):read("*a")) or ""
  pcall(os.remove, file_path)

  MiniTest.expect.equality(true, ok, "on_exit should fire within 5s")
  MiniTest.expect.equality(true, handle ~= nil)
  MiniTest.expect.equality("number", type(pid))
  MiniTest.expect.equality(true, sandbox_used)
  MiniTest.expect.equality("string", type(returned_name))
  MiniTest.expect.equality(sandbox_name, returned_name)
  if exit_code ~= nil then
    MiniTest.expect.equality(0, exit_code)
  end
  Helpers.expect_contains("hello", content)
end

T["kill: real sandlock kill terminates sandbox"] = function()
  if not Helpers.should_test_backend("sandlock") then
    MiniTest.skip("sandlock not selected")
  end

  local uv = vim.uv
  local file_path = "/tmp/cc-sb-real-kill-" .. math.random(10000, 99999) .. ".out"
  local fd = uv.fs_open(file_path, "w", 420)
  MiniTest.expect.equality(true, fd ~= nil)

  local done = false
  local kill_callback_fired = false
  local sandbox_name = "cc-sb-real-kill-" .. math.random(10000, 99999)
  local handle, pid = backend.run({ profile = Helpers.sandbox_profile_path() }, {
    cmd = "sleep 30",
    fd = fd,
    on_exit = function()
      done = true
    end,
    resolved_rules = common_rules,
    sandbox_name = sandbox_name,
  })

  if handle then
    uv.unref(handle)
  end

  vim.wait(500, function()
    return false
  end, 50, true)

  backend.kill({}, sandbox_name, pid, function()
    kill_callback_fired = true
  end)

  local ok = vim.wait(5000, function()
    return done and kill_callback_fired
  end, 50, true)
  pcall(uv.fs_close, fd)
  pcall(os.remove, file_path)

  MiniTest.expect.equality(true, ok, "process should exit and kill callback should fire")
end

return T
