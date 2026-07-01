--[[
Test: sandbox/init.lua — Facade dispatch and defaults

Intent: Verify facade dispatches to correct backend by opts.backend,
generates sandbox_name as run() 4th return value, validates unknown
backends, and handles non-sandbox kill behavior. End-to-end backend
contract tests live in test_sandbox_backends.lua.
]]

local uv = vim.uv
local Helpers = require("tests.helpers")
local sandbox = require("codecompanion._extensions.run_bash.sandbox")

local T = MiniTest.new_set()

-- Module exists
do
  local ok, _ = pcall(require, "codecompanion._extensions.run_bash.sandbox")
  T["facade exists"] = function()
    MiniTest.expect.equality(true, ok)
  end
end

-- ── Facade dispatch / signature tests ────────────────────────────

T["facade: is_available false when backend=false"] = function()
  MiniTest.expect.equality(false, sandbox.is_available({ backend = false }))
end

T["facade: is_available false when nil opts"] = function()
  MiniTest.expect.equality(false, sandbox.is_available(nil))
end

T["facade: is_available false when backend=nil"] = function()
  MiniTest.expect.equality(false, sandbox.is_available({ backend = nil }))
end

T["facade: should_use false when skip_sandbox=true"] = function()
  MiniTest.expect.equality(
    false,
    sandbox.should_use({ skip_sandbox = true }, { backend = "sandlock" })
  )
end

T["facade: should_use false when backend disabled"] = function()
  MiniTest.expect.equality(false, sandbox.should_use({ skip_sandbox = false }, { backend = false }))
end

T["facade: unknown backend errors with descriptive message"] = function()
  local ok, err = pcall(function()
    sandbox.is_available({ backend = "unknown" })
  end)
  MiniTest.expect.equality(false, ok)
  MiniTest.expect.equality(
    true,
    type(err) == "string" and err:find("unknown backend") ~= nil,
    "error should mention 'unknown backend': " .. tostring(err)
  )
end

T["facade: run returns sandbox_name for naming backend"] = function()
  -- Use spawn spy so we don't actually invoke sandlock
  local function spawn_stub(exe, opts, on_exit)
    return {}, 12345
  end
  local function no_op() end

  local _, _, sandbox_used, sandbox_name = sandbox.run({
    backend = "sandlock",
    rules = {},
    backends = { sandlock = { profile = "/tmp/fake.toml" } },
  }, {
    cmd = "echo hi",
    fd = 3,
    use_sandbox = true,
    on_exit = no_op,
    deps = { spawn = spawn_stub, unref = no_op },
  })

  MiniTest.expect.equality(true, sandbox_used)
  MiniTest.expect.equality(
    true,
    sandbox_name ~= nil,
    "sandbox_name should be non-nil for naming backend"
  )
  MiniTest.expect.equality(true, type(sandbox_name) == "string")
  MiniTest.expect.equality(true, vim.startswith(sandbox_name, "cc-bash-"))
end

T["facade: run returns nil sandbox_name for non-naming backend"] = function()
  local bw_path = "codecompanion._extensions.run_bash.sandbox.backends.bubblewrap"
  package.loaded[bw_path] = {
    capabilities = function()
      return { named_sandbox = false }
    end,
    run = function(opts, exec_params)
      local deps = exec_params.deps or {}
      local spawn = deps.spawn or uv.spawn
      local unref = deps.unref or uv.unref
      local handle, pid = spawn("bwrap", {
        args = {},
        stdio = { nil, exec_params.fd, exec_params.fd },
      }, exec_params.on_exit)
      if handle then
        unref(handle)
      end
      return handle, pid
    end,
    kill = function() end,
    validate_opts = function()
      return nil
    end,
    is_available = function()
      return true
    end,
    get_description = function()
      return "bubblewrap"
    end,
  }

  local function spawn_stub()
    return {}, 99999
  end
  local function no_op() end

  local _, _, _, sandbox_name = sandbox.run(
    { backend = "bubblewrap", rules = {}, backends = { bubblewrap = {} } },
    {
      cmd = "echo hi",
      fd = 3,
      use_sandbox = true,
      on_exit = no_op,
      deps = { spawn = spawn_stub, unref = no_op },
    }
  )

  MiniTest.expect.equality(nil, sandbox_name)

  package.loaded[bw_path] = nil
end

T["facade: kill dispatches to sandlock backend with opts"] = function()
  local captured = {}
  local function spawn_stub(exe, opts, on_exit)
    captured.exe = exe
    captured.args = opts.args
    if on_exit then
      on_exit()
    end
    return {}, 99999
  end
  local function no_op() end

  sandbox.kill(
    { backend = "sandlock", backends = { sandlock = { profile = "/tmp/fake.toml" } } },
    "test-sb",
    12345,
    nil,
    { spawn = spawn_stub, close = no_op, unref = no_op }
  )

  MiniTest.expect.equality("sandlock", captured.exe)
  MiniTest.expect.equality("kill", (captured.args or {})[1])
  MiniTest.expect.equality("test-sb", (captured.args or {})[2])
end

T["facade: should_use true when backend available"] = function()
  package.loaded["codecompanion._extensions.run_bash.sandbox.backends.bubblewrap"] = {
    is_available = function()
      return true
    end,
    capabilities = function() end,
    run = function() end,
    kill = function() end,
    validate_opts = function() end,
    get_description = function() end,
  }
  local result = sandbox.should_use({ skip_sandbox = false }, { backend = "bubblewrap" })
  MiniTest.expect.equality(true, result)
  package.loaded["codecompanion._extensions.run_bash.sandbox.backends.bubblewrap"] = nil
end

T["facade: is_available dispatches to backend"] = function()
  local called = false
  local backend = {
    is_available = function(opts)
      called = true
      return opts.ready
    end,
    capabilities = function() end,
    run = function() end,
    kill = function() end,
    validate_opts = function() end,
    get_description = function() end,
  }
  package.loaded["codecompanion._extensions.run_bash.sandbox.backends.bubblewrap"] = backend
  local result =
    sandbox.is_available({ backend = "bubblewrap", backends = { bubblewrap = { ready = true } } })
  MiniTest.expect.equality(true, called)
  MiniTest.expect.equality(true, result)
  package.loaded["codecompanion._extensions.run_bash.sandbox.backends.bubblewrap"] = nil
end

T["facade: get_description dispatches to backend"] = function()
  package.loaded["codecompanion._extensions.run_bash.sandbox.backends.bubblewrap"] = {
    is_available = function() end,
    capabilities = function() end,
    run = function() end,
    kill = function() end,
    validate_opts = function() end,
    get_description = function()
      return "bw-desc"
    end,
  }
  local desc = sandbox.get_description({ backend = "bubblewrap" })
  MiniTest.expect.equality("bw-desc", desc)
  package.loaded["codecompanion._extensions.run_bash.sandbox.backends.bubblewrap"] = nil
end

T["facade: validate_backend_opts dispatches to backend"] = function()
  package.loaded["codecompanion._extensions.run_bash.sandbox.backends.bubblewrap"] = {
    is_available = function() end,
    capabilities = function() end,
    run = function() end,
    kill = function() end,
    validate_opts = function(opts)
      return opts.missing and "missing" or nil
    end,
    get_description = function() end,
  }
  local err = sandbox.validate_backend_opts({
    backend = "bubblewrap",
    backends = { bubblewrap = { missing = true } },
  })
  MiniTest.expect.equality("missing", err)
  package.loaded["codecompanion._extensions.run_bash.sandbox.backends.bubblewrap"] = nil
end

T["facade: sandboxed run returns nil handle propagates error"] = function()
  local function spawn_stub(exe, opts, on_exit)
    return nil, "spawn failed"
  end
  local function no_op() end

  local handle, err, sandbox_used, sandbox_name = sandbox.run({
    backend = "sandlock",
    rules = {},
    backends = { sandlock = { profile = "/tmp/fake.toml" } },
  }, {
    cmd = "echo hi",
    fd = 3,
    use_sandbox = true,
    on_exit = no_op,
    deps = { spawn = spawn_stub, unref = no_op },
  })

  MiniTest.expect.equality(nil, handle)
  MiniTest.expect.equality("spawn failed", err)
  MiniTest.expect.equality(true, sandbox_used)
  MiniTest.expect.equality("string", type(sandbox_name))
end

T["facade: non-sandbox run returns nil handle propagates error"] = function()
  local function spawn_stub(exe, opts, on_exit)
    return nil, "no bash"
  end
  local function no_op() end

  local handle, err, sandbox_used, sandbox_name = sandbox.run({ backend = false }, {
    cmd = "echo hi",
    fd = 3,
    use_sandbox = false,
    on_exit = no_op,
    deps = { spawn = spawn_stub, unref = no_op },
  })

  MiniTest.expect.equality(nil, handle)
  MiniTest.expect.equality("no bash", err)
  MiniTest.expect.equality(false, sandbox_used)
  MiniTest.expect.equality(nil, sandbox_name)
end

T["facade: non-sandbox kill dispatches to two_stage_kill"] = function()
  local called = {}
  local orig = sandbox._internal.two_stage_kill
  sandbox._internal.two_stage_kill = function(pid, on_killed, deps)
    called.pid = pid
    called.on_killed = on_killed
    if on_killed then
      on_killed()
    end
  end

  sandbox.kill({ backend = false }, nil, 12345)

  sandbox._internal.two_stage_kill = orig
  MiniTest.expect.equality(12345, called.pid)
end

T["facade: non-sandbox kill delivers SIGTERM before SIGKILL"] = function()
  -- Intent: Verify non-sandbox kill uses two-stage SIGTERM → delayed SIGKILL.
  -- The trap handler proves SIGTERM arrived before SIGKILL;
  -- SIGKILL alone would kill the process without the trap firing.
  local file_path = "/tmp/cc-test-kill-seq-" .. math.random(10000, 99999) .. ".out"
  local fd = uv.fs_open(file_path, "w", 384)
  MiniTest.expect.equality(true, fd ~= nil)

  local done = false
  local callback_fired = false

  local handle, pid = sandbox.run({ backend = false }, {
    cmd = "trap 'echo SIGTERM_RECEIVED' TERM; sleep 30",
    fd = fd,
    file_path = file_path,
    use_sandbox = false,
    on_exit = function()
      done = true
    end,
  })

  if handle then
    uv.unref(handle)
  end

  -- Give trap time to be set in the child process
  vim.wait(300, function()
    return false
  end, 50, true)

  sandbox.kill({ backend = false }, nil, pid, function()
    callback_fired = true
  end)

  -- Wait for both process exit and kill callback (SIGTERM + 2s delay + SIGKILL)
  local ok = vim.wait(5000, function()
    return done and callback_fired
  end, 50, true)
  pcall(uv.fs_close, fd)
  local content = (uv.fs_stat(file_path) and io.open(file_path, "r"):read("*a")) or ""
  pcall(os.remove, file_path)

  MiniTest.expect.equality(true, ok, "process should die and callback should fire")
  Helpers.expect_contains("SIGTERM_RECEIVED", content)
end

T["facade: defaults has expected backends and rules"] = function()
  local defaults = sandbox.defaults
  MiniTest.expect.equality("sandlock", defaults.backend)
  MiniTest.expect.equality("table", type(defaults.rules.fs_readable))
  MiniTest.expect.equality("table", type(defaults.rules.fs_writable))
  MiniTest.expect.equality("table", type(defaults.rules.fs_denied))
  MiniTest.expect.equality("table", type(defaults.backends.sandlock))
  MiniTest.expect.equality("table", type(defaults.backends.bubblewrap))
end

T["non-sandbox: kill without callback does not error"] = function()
  local ok, err = pcall(sandbox.kill, { backend = false }, nil, 99999)
  MiniTest.expect.equality(true, ok, "kill without callback should not error: " .. tostring(err))
end

return T
